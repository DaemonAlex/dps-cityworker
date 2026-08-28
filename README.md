# DPS CityWorker

A living city-infrastructure job for FiveM. Clock in, drive to assigned jobs, and
use your target-eye to repair the city's grid — potholes, streetlights, water
pipes, electrical boxes, and more. Paid per task, so you can clock out whenever
you like. But it's far more than a fetch-and-repair loop: the city is a **living
system** that decays, blacks out, throws emergencies, and — when nobody's on
duty — quietly heals itself through NPC crews.

![Framework](https://img.shields.io/badge/framework-QB%20%7C%20QBX%20%7C%20ESX-green)
![UI](https://img.shields.io/badge/ui-ox__lib%20%2B%20NUI-orange)

## Features

### The living grid
- **Sector infrastructure health** — the map is divided into sectors, each with a
  health value persisted to the database.
- **Decay only when staffed** — sectors decay while workers are on duty; when
  nobody's clocked in, the grid holds steady (the city doesn't crumble just
  because no one took the shift).
- **Auto-recovery** — if a sector blacks out while unstaffed, simulated NPC crews
  slowly bring it back online. The world self-heals when neglected.
- **Blackouts** — sectors that fall below threshold trigger a blackout event.

### Emergencies
- **Random emergencies** — water main breaks, gas leaks, downed power lines,
  fallen trees — spawned at verified locations, alerted to all on-duty workers.
- **Weather-triggered events** — rain drives storm-drain work (with a pay bonus);
  storms can trigger fallen trees / downed lines.
- **Bonus pay + XP** for emergency response; stale emergencies auto-resolve when
  no one's available.

### Progression
- **25+ task types** across 5 ranks (maintenance, road, electrical, sewer,
  cleanup, utility, emergency).
- **XP, ranks, and rank-ups** with per-rank pay multipliers.
- **Scavenging** — a chance to find crafting materials on task completion.
- **Teamwork bonus** — up to +30% pay for working near other city workers.

### Foreman tools (rank 5+)
- **Control Room** — a live NUI dashboard of every sector's health, with the
  ability to dispatch crews.
- **Crew assignment** — assign specific tasks to on-duty workers.

### Sub-contractor companies
- **Register a company** (Senior Technician+, for a fee) at the Sub-Contractor
  Office ped, or via `/company`.
- **City contracts** — the city posts maintenance contracts (complete N jobs in a
  sector for a lump-sum budget). Accept one and fulfil it before the deadline.
- **Crews** — hire nearby on-duty workers; their completed tasks count toward your
  active contract, and they earn a cut of the payout on completion.
- **Company funds & reputation** — completed contracts pay into company funds
  (withdraw to your bank) and build reputation; expired contracts cost reputation.

### Other
- **Damage reports** — players can report infrastructure damage, logged to the DB.
- **Anti-exploit** — per-player completion cooldowns.
- **Admin commands** — set sector health, trigger emergencies.

## Dependencies
- [ox_lib](https://github.com/overextended/ox_lib) (UI, callbacks, commands)
- [oxmysql](https://github.com/overextended/oxmysql)
- [ox_target](https://github.com/overextended/ox_target)
- A supported framework: **QBox** / QBCore / ESX (auto-detected via the bundled bridge)

## Installation
1. Extract to your resources folder.
2. Import `sql/cityworker.sql` into your database.
3. Configure `config.lua` (sectors, ranks, economy) and `sv_config.lua`
   (vehicle spawn, task locations).
4. `ensure dps-cityworker` in your server.cfg (after ox_lib / oxmysql / your framework).

## Commands
| Command | Description |
|---|---|
| `/workstatus` | Check your rank, XP, and repair count |
| `/controlroom` | Open the Foreman Control Room dashboard (rank 5+) |
| `/company` | Open your sub-contractor company (register · contracts · crew · funds) |
| `/reportdamage [type]` | Report infrastructure damage at your location |
| `/setsectorhealth <sector> <health>` | *(admin)* set a sector's health |
| `/triggeremergency <type> <sector>` | *(admin)* trigger an emergency |

## Notes
- The UI follows the DelPerroSands house style (coastal-dusk).

---
*DPS Development — part of the DelPerroSands server stack.*
