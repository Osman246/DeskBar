// Apple Silicon has no public temperature API. The private IOHIDEventSystem
// client below is what Activity Monitor-style tools use; it needs no
// permissions but could change in a future macOS release.
#include "Sensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

typedef struct __HIDClient *HIDClientRef;
typedef struct __HIDService *HIDServiceRef;
typedef struct __HIDEvent *HIDEventRef;

HIDClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(HIDClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(HIDClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(HIDServiceRef service, CFStringRef key);
HIDEventRef IOHIDServiceClientCopyEvent(HIDServiceRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(HIDEventRef event, int32_t field);

enum { kTemperatureEvent = 15, kTemperatureField = 15 << 16 };

static HIDClientRef client(void) {
    static HIDClientRef shared;
    if (shared) return shared;
    shared = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!shared) return NULL;
    int page = 0xff00, usage = 5;  // Apple vendor page, temperature sensors
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(shared, match);
    CFRelease(match); CFRelease(p); CFRelease(u);
    return shared;
}

// The CPU die sensors, found once and kept (looking them up costs ~10 ms each time).
static CFMutableArrayRef die_sensors;

static void find_die_sensors(void) {
    if (die_sensors) return;
    HIDClientRef c = client();
    if (!c) return;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(c);
    if (!services) return;
    die_sensors = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        HIDServiceRef service = (HIDServiceRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!name) continue;
        // "PMU tdie<n>" are the CPU die sensors on M-series chips.
        if (CFStringHasPrefix(name, CFSTR("PMU tdie"))) CFArrayAppendValue(die_sensors, service);
        CFRelease(name);
    }
    CFRelease(services);
}

double sensors_cpu_temperature(void) {
    find_die_sensors();
    if (!die_sensors) return -1;
    double hottest = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(die_sensors); i++) {
        HIDServiceRef service = (HIDServiceRef)CFArrayGetValueAtIndex(die_sensors, i);
        HIDEventRef event = IOHIDServiceClientCopyEvent(service, kTemperatureEvent, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, kTemperatureField);
        CFRelease(event);
        if (value > 0 && value < 150 && value > hottest) hottest = value;
    }
    return hottest;
}

// MARK: Fans, via the System Management Controller (AppleSMC).

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key;
    SMCVersion vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCParam;

enum { kSMCUserClientCall = 2, kSMCReadBytes = 5, kSMCReadKeyInfo = 9 };

static io_connect_t smc(void) {
    static io_connect_t connection;
    if (connection) return connection;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    if (IOServiceOpen(service, mach_task_self(), 0, &connection) != kIOReturnSuccess) connection = 0;
    IOObjectRelease(service);
    return connection;
}

static int smc_read(const char *key, SMCParam *out) {
    io_connect_t c = smc();
    if (!c) return -1;
    SMCParam in = {0};
    size_t size = sizeof(SMCParam);
    in.key = (UInt32)key[0] << 24 | (UInt32)key[1] << 16 | (UInt32)key[2] << 8 | (UInt32)key[3];
    in.data8 = kSMCReadKeyInfo;
    if (IOConnectCallStructMethod(c, kSMCUserClientCall, &in, sizeof in, out, &size) != kIOReturnSuccess || out->result)
        return -1;
    SMCKeyInfo info = out->keyInfo;
    in.data8 = kSMCReadBytes;
    in.keyInfo.dataSize = info.dataSize;
    if (IOConnectCallStructMethod(c, kSMCUserClientCall, &in, sizeof in, out, &size) != kIOReturnSuccess || out->result)
        return -1;
    out->keyInfo = info;
    return 0;
}

int sensors_fan_speeds(double *rpm, int max) {
    SMCParam p;
    if (smc_read("FNum", &p)) return 0;
    int count = p.bytes[0];
    for (int i = 0; i < count && i < max; i++) {
        char key[5];
        snprintf(key, sizeof key, "F%dAc", i);
        float value = 0;
        if (!smc_read(key, &p) && p.keyInfo.dataSize == 4) memcpy(&value, p.bytes, 4);  // "flt " on Apple Silicon
        rpm[i] = value;
    }
    return count;
}

// MARK: External display brightness over DDC/CI (Apple Silicon).
// Same approach as MonitorControl and m1ddc: talk I2C to the monitor through the
// display controller's private IOAVService.

#include <unistd.h>

typedef CFTypeRef IOAVServiceRef;
IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chip, uint32_t offset, void *buffer, uint32_t length);
IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chip, uint32_t offset, void *buffer, uint32_t length);

enum { kDDCChip = 0x37, kDDCOffset = 0x51, kVCPBrightness = 0x10, kMaxDDC = 8 };

static IOAVServiceRef ddc_services[kMaxDDC];
static int ddc_count = -1;

static void ddc_scan(void) {
    if (ddc_count >= 0) return;
    ddc_count = 0;
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)) return;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) && ddc_count < kMaxDDC) {
        CFStringRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
        Boolean external = location && CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location) CFRelease(location);
        if (external) {
            IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
            if (av) ddc_services[ddc_count++] = av;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
}

int ddc_display_count(void) {
    ddc_scan();
    return ddc_count;
}

int ddc_get_brightness(int index) {
    ddc_scan();
    if (index < 0 || index >= ddc_count) return -1;
    UInt8 request[4] = { 0x82, 0x01, kVCPBrightness, 0 };
    request[3] = 0x6E ^ kDDCOffset ^ request[0] ^ request[1] ^ request[2];
    for (int attempt = 0; attempt < 3; attempt++) {
        UInt8 reply[12] = { 0 };
        usleep(10000);
        if (IOAVServiceWriteI2C(ddc_services[index], kDDCChip, kDDCOffset, request, 4)) continue;
        usleep(40000);
        if (IOAVServiceReadI2C(ddc_services[index], kDDCChip, kDDCOffset, reply, 12)) continue;
        if (reply[2] != 0x02 || reply[4] != kVCPBrightness) continue;  // not a "VCP reply" for brightness
        int max = reply[6] << 8 | reply[7], current = reply[8] << 8 | reply[9];
        return max > 0 ? current * 100 / max : current;
    }
    return -1;
}

int ddc_set_brightness(int index, int value) {
    ddc_scan();
    if (index < 0 || index >= ddc_count) return -1;
    if (value < 0) value = 0;
    if (value > 100) value = 100;
    UInt8 data[6] = { 0x84, 0x03, kVCPBrightness, (UInt8)(value >> 8), (UInt8)(value & 0xFF), 0 };
    data[5] = 0x6E ^ kDDCOffset ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];
    IOReturn result = kIOReturnError;
    for (int attempt = 0; attempt < 2; attempt++) {  // monitors sometimes drop the first write
        usleep(10000);
        result = IOAVServiceWriteI2C(ddc_services[index], kDDCChip, kDDCOffset, data, 6);
    }
    return result == kIOReturnSuccess ? 0 : -1;
}
