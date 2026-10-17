# Shree Glass Hardware — Flutter Android app

An offline-first cash book and receipt app for Shree Glass Hardware.

## Features

- Dashboard for today's money-in, money-out, total money-in/out, and net recorded balance.
- Money-in sales with multiple item rows, description, rate, quantity/sq.ft, automatic line totals, customer name, village, bill number and date.
- Cash or Online / UPI payment mode.
- Record amount collected and automatically calculate remaining customer balance.
- Money-out expenses/purchases with supplier name, item details, payment mode, amount paid, and remaining supplier balance.
- Local SQLite storage on the device; no account or cloud connection required.
- Generates a PDF receipt after saving a money-in entry. Receipt includes shop branding, mobile number, bill/date/customer, line items, total, amount in words, amount collected, balance remaining, payment mode, and a light brand watermark.
- Save a PDF copy inside the app's `Receipts` folder. The Android share sheet lets you send it with WhatsApp or another app; use the available save/share destination to export a copy. The file name includes customer name, date, and bill number.
- Edit/delete entries and access receipts from transaction history.

## Build locally

Install Flutter stable and Android Studio/Android SDK, then from this folder run:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`.

## Build with GitHub Actions

The workflow at `.github/workflows/build-apk.yml` builds the release APK on every push to `main`/`master` and supports manual runs from **Actions → Build Shree Glass Android APK → Run workflow**. On success, download `shree-glass-release-apk` from the run's **Artifacts** section.

The workflow removes the old default Flutter `test/widget_test.dart` from the checked-out project before analysis, preventing the stale `MyApp` template test from breaking the build.

## Data and receipt storage

Transactions are stored in the app's local SQLite database. Receipt PDFs are saved in the app's private documents directory under `Receipts/`, with filenames like `Customer_Name_2026-10-17_Bill_12.pdf`. Share/export the PDF if you need it in Downloads, WhatsApp, Drive, or another location visible outside the app.

## Verification note

The source includes automated unit tests and a GitHub Actions build workflow. A release APK is only verified once the workflow completes successfully; this environment did not have the Flutter SDK available for a local Android build.
