# Move Social and Voice

World of Warcraft **retail** add-on that adds a draggable handle so you can reposition **ChatAlertFrame** — the stack used for voice/speaker bubbles and related chat alerts. **Quick Join** and channel UI that anchor to that stack move with it.

## Install

Copy the `MoveSocialAndVoice` folder into:

`World of Warcraft\_retail_\Interface\AddOns\`

Enable **Move Social and Voice** in the AddOns list (character select or in-game). The add-on loads after **Blizzard_Channels**.

## Usage

- **Esc → Options → AddOns → Move Social and Voice** — unlock to show the handle, lock when finished.
- **Slash:** `/mvo` or `/movevoice`
  - `unlock` / `on` — show handle and drag
  - `lock` / `off` — hide handle and save position
  - `toggle` — flip unlock
  - `reset` — default position (top center)
  - `recover` — clear bad saved data, unlock, show handle
  - `config` — open options (if available)

Settings are stored per character in `MoveSocialAndVoiceDB`.

## Requirements

- Retail WoW with an `## Interface:` build supported by the `.toc` (update the Interface line when Blizzard raises the API version).

## License

This project is dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/) — see [LICENSE](LICENSE).
