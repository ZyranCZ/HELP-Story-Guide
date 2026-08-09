

# HELP - Story Guide

**HELP - Story Guide is primarily intended for players who have never played Generation I Pokémon games and do not want to constantly Google what they are supposed to do next.**

<img width="1548" height="1410" alt="image" src="https://github.com/user-attachments/assets/51e28bb8-5565-4c4b-8776-8d8720bf04cd" />

Pokémon Red/Blue were created in an era when games often gave the player very little direction. Sometimes the intended next step is obvious, but sometimes the game simply leaves you wandering around until you discover the solution — occasionally almost by accident.

With this mod, you can simply open **HELP** and ask the game itself what you can or should do next.

The guide reads your current save state and tries to understand what you have already completed, what is currently available, and which progression paths are still open.

<img width="1026" height="800" alt="image" src="https://github.com/user-attachments/assets/5130bdb2-6c2e-4c2b-a094-28d61bb0b6ed" />

## Features

- Adds **HELP** to the START menu.
- Detects current story progress directly from the save.
- Shows the next recommended objective.
- Supports multiple valid objectives when the game becomes non-linear.
- Shows unfinished optional progression-related content.
- Tracks trainers on accessible Routes:
  - `Trainers defeated: X/Y`
- Works with already-progressed saves.
- Understands alternative progression orders and common sequence breaks.
- Checks important items in both the Bag and PC Item Storage.
- Supports **HM Anywhere**.
- Handles special progression cases where normal trainer/event logic is not enough.
<img width="1026" height="800" alt="image" src="https://github.com/user-attachments/assets/103f2c38-7e13-4ec6-8712-5050961a4426" />

**Check out my other mods:**<br>
* [Autofire A/B + Directional Keys Mod](https://github.com/ZyranCZ/autofire)<br>
* [Steel and/or Fairy and/or Typing Charts](https://github.com/ZyranCZ/Steel-and-or-Fairy-and-or-Typing-Charts)<br>
* [Move Category (PHYS/SPEC) Preview](https://github.com/ZyranCZ/Move-Category-Preview)<br>
* [Special Stat Split
](https://github.com/ZyranCZ/Special-Stat-Split/)<br>
* [Enemy HP Visible](https://github.com/ZyranCZ/Enemy-HP)
* [Can Always Escape](https://github.com/ZyranCZ/Can-Always-Escape)
* [Trainers Let You Choose Lead Pokemon](https://github.com/ZyranCZ/Trainers-Let-You-Choose-Lead-Pokemon)
* [Evolve in Battle](https://github.com/ZyranCZ/Evolve-in-Battle)
* [HELP Story Guide](https://github.com/ZyranCZ/HELP-Story-Guide/)


## HELP pages

Depending on the current game state, HELP may show several pages:

- **CURRENT STEP** – what to do in the area you are currently progressing through.
- **NEXT OBJECTIVE** – the main recommended next step.
- **OTHER OPTION** – another currently valid progression path.
- **UNFINISHED** – optional or skipped progression-related content.
- **ROUTE TRAINERS** – remaining trainers on Routes you can currently access.

Use **A / SELECT / Left / Right** to move between pages and **B** to close HELP.

## SELECT shortcut

HELP can optionally be opened directly with **SELECT** while walking in the overworld.

This is **disabled by default**.

It can be enabled in the settings of the HELP mod:

`SELECT HELP: OFF / ON`

## Items stored in the PC

HELP checks both your Bag and PC Item Storage.

If an important progression item is stored in the PC, the guide will not incorrectly tell you to obtain it again.

Instead, it explains what to do with it, for example:

`Withdraw POKE FLUTE from PC and wake the Snorlax south of Lavender Town.`

## HMs

HELP distinguishes between:

- owning an HM,
- having the HM stored in the PC,
- having the move already learned by a Pokémon,
- having the required Badge.

For progression-critical HMs such as **CUT, SURF and STRENGTH**, HELP only asks you to teach the move when it is actually necessary.

**FLY and FLASH are treated as optional** and are not forced as main-story objectives.

### HM Anywhere compatibility

If **HM Anywhere** is active, HELP takes it into account.

An HM in the Bag plus the required Badge is treated as usable even if no Pokémon knows the move.

If the HM is stored in the PC, HELP tells you to withdraw it instead of telling you to teach it to a Pokémon.

## Alternative routes and sequence breaks

The guide follows what you have actually accomplished rather than forcing one fixed walkthrough.

It supports situations such as:

- Gym Leaders defeated in an unusual order,
- traded Pokémon already knowing HM moves,
- Poké Doll / Pokémon Tower sequence breaks,
- progression items stored in the PC,
- alternate routes to Fuchsia City,
- one optional path completed while another remains unfinished,
- installing the mod in the middle of an existing playthrough.

Skipped content may remain available as an **UNFINISHED** page without blocking your main progression.

## Route trainer tracking

HELP tracks trainers using the actual save state.

This means Route progress can still be reconstructed when the mod is installed halfway through a playthrough.

The tracker also accounts for special cases such as:

- scripted trainers that do not use normal Route trainer logic,
- trainers that only become accessible later,
- trainers behind HM requirements such as SURF.

A trainer that cannot currently be reached is not treated as an unfinished objective yet.

## Feedback

Testing a mod like this in every possible real playthrough is difficult.

Pokémon Red/Blue allow many different progression orders, optional areas, sequence breaks, unusual save states and combinations with other mods.

If you encounter anything that:

- does not match your actual progress,
- tells you to do something you have already completed,
- misses an available objective,
- recommends a clearly suboptimal route,
- or simply feels confusing,

**please leave a comment / issue describing what happened and what your current game state was.**

Real playthrough feedback is extremely useful for improving the guide.

## Compatibility

Designed for:

- **Gen1Recomp**
- Mod API 2

No engine-internals permission is required.
