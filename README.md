# Garajku — Repo Structure

```
garajku/
├── shared/
│   └── index.html          ← EDIT THIS ONE — shared between both apps
├── garajku-android/        ← Android app (existing)
│   └── app/src/main/assets/index.html   (do not edit directly)
├── garajku-ios/            ← iOS app (new)
│   └── garajku-ios/garajku-ios/index.html  (do not edit directly)
├── sync.bat                ← Run after editing shared/index.html
└── .github/workflows/
    └── build-ios.yml       ← Auto-builds iOS IPA on every push
```

## Workflow

1. Edit `shared/index.html`
2. Double-click `sync.bat`
3. Rebuild Android in Android Studio
4. `git push` → GitHub Actions builds the iOS IPA automatically
5. Download IPA from GitHub → Actions tab → latest run → Artifacts
6. Sideload with AltStore

## iOS first-time setup

See SETUP.md for AltStore installation steps.

## Config

- Android: `garajku-android/app/src/main/java/com/garajku/Config.kt`
- iOS: `garajku-ios/garajku-ios/garajku-ios/Config.swift`

Change `carBtName` / `CAR_BT_NAME` in both to your Honda City head unit name.
