# Lost Green

Lost Green is an indoor bike trainer desktop application for:

- connecting fitness devices (smart trainers, power meters, cadence sensors, and heart-rate monitors)
- running structured workouts (including ERG control targets)
- collecting ride data in real time for post-workout analysis

## Architecture

This project is built with **Elixir Phoenix + Tauri**.

- `src-elixir`: the Phoenix app (UI + backend logic + persistence)
- `src-tauri`: the desktop host and machine bridge (Bluetooth/WiFi access, sidecar lifecycle)

Why this split:

- The Phoenix app provides the full product UI and application logic.
- Tauri provides a native desktop shell and device access where browser APIs are limited.
- In production, Tauri runs the Phoenix release as a sidecar binary (`lost_green_backend-*`).

## Run locally

### Prerequisites

- Elixir/Erlang toolchain (compatible with `mix` in this repo)
- Rust toolchain (`cargo`)
- Tauri CLI (`cargo install tauri-cli`)
- macOS developer tooling (Xcode Command Line Tools)

### Toolchain management (`mise`)

`mise` is recommended for managing Erlang/Elixir/Rust versions locally.

This repository includes a project toolchain file at [`mise.toml`](mise.toml).

From the repository root:

```bash
mise trust
mise install
```

Then install the Tauri CLI:

```bash
cargo install tauri-cli
```

### 1) Install and set up dependencies

From `src-elixir`:

```bash
mix setup
```

### 2) Start Phoenix (terminal A)

From `src-elixir`:

```bash
mix phx.server
```

### 3) Start Tauri (terminal B)

From `src-tauri`:

```bash
SIMULATE_DEVICES=1 cargo tauri dev
```

Notes:

- `SIMULATE_DEVICES` accepts `1`, `true`, `yes`, or `on`.
- In debug, Tauri first checks for an external backend at `http://localhost:4000`.
- If Phoenix is already running, Tauri uses it directly; otherwise it attempts sidecar startup.

## Release build (macOS)

Run from the repository root:

```bash
./scripts/release.sh
```

Optional flags:

```bash
./scripts/release.sh --target x86_64-apple-darwin
./scripts/release.sh --skip-tauri-build
```

What `scripts/release.sh` does:

1. Builds Phoenix production assets and code.
2. Builds the Burrito desktop backend release (`lost_green_desktop`).
3. Copies Burrito output to the Tauri sidecar path (`src-tauri/lost_green_backend-<target>`).
4. Regenerates/prunes Tauri icons and runs `cargo tauri build` (unless skipped).

Bundle output is written under:

- `src-tauri/target/<target>/release/bundle`

## Release targets

Current release support is **macOS only**.

- Default target in release script: `aarch64-apple-darwin`
- Optional Intel macOS target: `x86_64-apple-darwin`
- Burrito release config currently only defines macOS (`aarch64`) packaging.

Linux and Windows may work once additional Burrito targets are configured in [`src-elixir/mix.exs`](src-elixir/mix.exs) (`releases/0`) and the sidecar/bundling wiring is updated accordingly.

## Contributor checks

Before opening a PR from `src-elixir`, run:

```bash
mix precommit
```

## Troubleshooting

- `cargo tauri dev` cannot find backend sidecar:
	- Start Phoenix first in `src-elixir` with `mix phx.server`.
	- Or create/update the sidecar with `./scripts/release.sh --skip-tauri-build`.
- Tauri opens but app is blank/unreachable:
	- Verify Phoenix is serving on `http://localhost:4000`.
	- Ensure nothing else is using port `4000`.
- No devices found during development:
	- Run with simulated devices enabled: `SIMULATE_DEVICES=1 cargo tauri dev`.
	- Accepted values are `1`, `true`, `yes`, or `on`.

