# Aether — showcase website

Static "vitrine" site for the Aether iPhone app, plus the Privacy Policy and
Support pages required for App Store Connect.

Plain HTML + CSS, no build step, no framework. Hosted on **GitHub Pages**;
canonical base `https://glandais.github.io/aether/`.

## Structure

```
web/
├── index.html          landing / showcase
├── privacy/index.html  Privacy Policy   → App Store "Privacy Policy URL"
├── support/index.html  Support page     → App Store "Support URL"
├── assets/style.css    design system (twilight theme)
├── favicon.svg         site mark
├── icon.png            1024² app icon (copied from the app)
└── .nojekyll           disable Jekyll processing on GitHub Pages
```

## Preview locally

```sh
cd web && python3 -m http.server 8000   # then open http://localhost:8000
```

## Deploy (GitHub Pages)

Publish the `web/` folder (e.g. Pages → "Deploy from a branch", or a workflow
that uploads `web/` as the Pages artifact). All links are relative, so the site
works under the `/aether/` subpath.

## Screenshots

The hero and the four landscape cards currently use hand-built CSS art. Real
simulator captures can be dropped in at the slots marked
`<!-- SCREENSHOT SLOT: ... -->` in `index.html` (capture per the project's
"Build & vérification" section in `../CLAUDE.md`).

## App Store URLs to register

- Support URL: `https://glandais.github.io/aether/support/`
- Privacy Policy URL: `https://glandais.github.io/aether/privacy/`
