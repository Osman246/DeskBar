# Contributing

Thanks for taking a look. Issues and pull requests are welcome.

## Before you start

Read [docs/PRODUCT.md](docs/PRODUCT.md). The panel is deliberately small, so new features should
answer a real question someone has about their Mac. Open an issue before building anything large.

## Building

```bash
./build.sh && open DeskBar.app
```

## Checking your change

- **Visual changes:** render the panel offscreen and look at the PNGs.
  ```bash
  ./DeskBar.app/Contents/MacOS/DeskBar --snapshot out/
  ```
  Use `DESKBAR_DEMO=1` for screenshots you'll post in an issue or PR, so your IP and Mac name stay
  private.
- **Anything that runs continuously:** leave the app open on the affected page for a few minutes, and
  check that memory and CPU stay flat (`top -pid $(pgrep -x DeskBar)`).
- **Avoid `.pickerStyle(.segmented)` in content that updates often.** Use `Segments` instead (see
  docs/PRODUCT.md for why).

## Style

Match the code around you. Keep comments short, saying why rather than what, and write UI text in
plain sentence case.
