<p align="center">
  <img src="icon.png" width="128" />
</p>

<h1 align="center">pscan</h1>

<p align="center">
  Menu bar app to monitor and manage your localhost ports.
</p>

<p align="center">
  <a href="https://github.com/mavideniz/pscan/releases/latest">Download</a> · <a href="#cli">CLI</a> · <a href="#license">License</a>
</p>

---

<p align="center">
  <img src="screenshot.png" width="420" />
</p>

## Features

- See active development processes and ports at a glance from the menu bar
- Group multiple listening ports by project
- Project and Git worktree detection
- CPU, memory, and uptime summaries
- Search by project, port, PID, runtime, path, or command
- Switch between development services and all listening ports from the menu bar
- Sort projects by name, CPU, memory, or uptime
- Open in browser, Terminal, or Finder with one click
- Stop, force-stop, or terminate a managed process tree
- Active development process count badge
- Launch at login
- Configurable via Options window

## Install

### Menu Bar App

Download the latest `.zip` from [Releases](https://github.com/mavideniz/pscan/releases/latest) or [World Vibe Web](https://wvw.dev), unzip, and move `pscan.app` to Applications.

### CLI

```
brew install mavideniz/pscan/pscan
```

Or build from source:

```
swift build -c release
cp .build/release/pscan /usr/local/bin/pscan
```

## CLI

```
$ pscan
PORT    PROCESS       PROJECT               DIRECTORY
────────────────────────────────────────────────────────────────────────
:3000   node          finance-web           ~/Developer/finance-web
:3001   node          admin-panel           ~/Developer/admin-panel
:5173   vite          landing-page          ~/Developer/landing-page
```

### Options

| Flag | Description |
|------|-------------|
| `-a, --all` | Show all ports including system services |
| `-j, --json` | Output as JSON |
| `-k, --kill PORT` | Kill the process on a given port |
| `-h, --help` | Show help |

## Requirements

- macOS 13+

## License

[MIT](LICENSE)
