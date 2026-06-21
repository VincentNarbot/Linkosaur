<p align="center">
  <img src="Resources/LinkosaurIcon.png" width="128" alt="Linkosaur app icon">
</p>

<h1 align="center">Linkosaur</h1>

<p align="center">
  A native macOS link router for keeping Work and Personal browsing separate.
</p>

Linkosaur becomes your default browser handler, then quietly forwards each link to the browser you choose. It runs locally as an invisible background app—no server, account, or browser extension required.

## Features

- Assign any installed browser to Work and Personal roles.
- Add, remove, and edit domain rules; a domain also matches its subdomains.
- Route each domain to Work, Personal, or Ask every time.
- Choose a default action for unmatched links.
- Runs invisibly; macOS launches it automatically when needed.
- Stores configuration in macOS user defaults.

Initial rules preserve the original setup: Formidable, GitHub, and AWS use Work; Google asks; everything else uses Personal.

Rules match URL hostnames, not arbitrary text elsewhere in a URL. For example, a `github.com` rule matches `docs.github.com`, but not `example.com/?next=github.com`.

## Requirements

- macOS 13 Ventura or newer
- Xcode Command Line Tools
- At least one browser besides Linkosaur

## Build and install

```sh
git clone https://github.com/VincentNarbot/Linkosaur.git
cd Linkosaur
./scripts/build.sh
./scripts/install.sh
```

The build uses Apple Clang and AppKit with no third-party dependencies. The install script places the app at `~/Applications/Linkosaur.app` and launches it.

On first launch, macOS asks to make Linkosaur the default browser. If needed, choose **Linkosaur** under **System Settings → Desktop & Dock → Default web browser**.

After setup, open `~/Applications/Linkosaur.app` manually whenever you want to change settings. Linkosaur does not need to be added to Login Items.

## How routing works

Rules are evaluated from top to bottom. The first matching domain decides whether a link opens with the Work browser, Personal browser, or an interactive picker. If no rule matches, Linkosaur uses the configured fallback action.

All routing and settings code currently lives in `Sources/Linkosaur/main.m`. The app bundle is assembled by `scripts/build.sh`, including the multi-resolution icon and URL-handler metadata.

## Privacy

Routing happens entirely on your Mac. Linkosaur has no networking, analytics, or URL logging. It only reads the incoming URL, applies your local rules, and passes the URL to the selected browser.

## License

Linkosaur is available under the [MIT License](LICENSE).
