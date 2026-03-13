Place a proxy core binary here to enable managed `vless://` startup inside the control app.

Supported runtime names:

- `sing-box`
- `xray`
- `sing-box.exe`
- `xray.exe`

The control app will also look in:

- `app/bin/<platform>-<arch>/sing-box`
- `app/bin/<platform>-<arch>/xray`

Examples:

- `app/bin/darwin-arm64/sing-box`
- `app/bin/win32-x64/xray.exe`
