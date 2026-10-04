# dps-cityworker

A city infrastructure job for Qbox servers: clock in at the depot, drive to assigned sites, repair them, and keep sector health up.

## Features

### Shift and tasks
- Talk to the boss ped at the depot (`Config.BossCoords`) with ox_target. Options: **Start Work** and **Finish Work**.
- Start Work spawns a work truck at `VehicleSpawn`, warps you in, sets the plate to `CITY####`, gives keys, and fills fuel to 100.
- You get one task at a time. A blip, a route, a prop and a target zone mark the site. Use the target option to start the repair.
- Each repair is a progress bar (easy 6 s, medium 8 s, hard 12 s), then an ox_lib skill check. Cancelling or failing the check gives no pay. You can try again.
- Pay is paid when the repair is done. The next task is dealt about 5 seconds later.
- Finish Work only works within 15 m of the boss ped. It saves your stats and deletes the truck. Disconnecting also saves your stats and deletes the truck.
- A task must be completed within 12 m of its assigned location, and at least 2 seconds apart.
- A map blip "City Worker Job" is shown at the depot.

Tasks by rank. A player gets random tasks from every task at or below their rank.

| Rank | Task id | Label | Category | XP | Sector repair | Difficulty |
|---|---|---|---|---|---|---|
| 1 | `pipe` | Water Pipe Repair | maintenance | 20 | 2.0 | easy |
| 1 | `pothole` | Pothole Repair | road | 15 | 1.5 | easy |
| 1 | `meter_reading` | Meter Reading | utility | 10 | 0.5 | easy |
| 1 | `graffiti` | Graffiti Removal | cleanup | 18 | 1.0 | easy |
| 1 | `trash` | Trash Collection | cleanup | 12 | 0.5 | easy |
| 2 | `streetlight` | Streetlight Repair | electrical | 25 | 2.5 | medium |
| 2 | `hydrant` | Fire Hydrant Inspection | maintenance | 22 | 1.5 | medium |
| 2 | `sign_repair` | Road Sign Repair | road | 20 | 1.0 | medium |
| 2 | `manhole` | Manhole Inspection | sewer | 28 | 2.0 | medium |
| 2 | `storm_drain` | Storm Drain Clearing | sewer | 25 | 2.0 | medium |
| 3 | `electrical` | Electrical Box Repair | electrical | 35 | 3.0 | medium |
| 3 | `traffic_control` | Traffic Control Setup | road | 30 | 1.5 | medium |
| 3 | `tree_trimming` | Tree Trimming | maintenance | 35 | 2.5 | medium |
| 3 | `cable_install` | Cable Installation | utility | 40 | 3.0 | medium |
| 4 | `transformer` | Transformer Maintenance | electrical | 50 | 5.0 | hard |
| 4 | `hazmat` | Hazmat Cleanup | cleanup | 60 | 4.0 | hard |
| 4 | `bridge_inspection` | Bridge Inspection | maintenance | 55 | 4.0 | hard |
| 4 | `utility_locating` | Utility Locating | utility | 45 | 2.0 | hard |

Emergency tasks (see Emergencies):

| Min rank | Task id | Label | XP | Sector repair | Difficulty |
|---|---|---|---|---|---|
| 2 | `water_main` | Water Main Break | 80 | 8.0 | hard |
| 3 | `gas_leak` | Gas Leak Response | 100 | 10.0 | hard |
| 4 | `downed_lines` | Downed Power Lines | 90 | 9.0 | hard |
| 2 | `fallen_tree` | Fallen Tree Removal | 70 | 6.0 | medium |

Notes:
- The task location comes from `CategoryLocations[category]` in `sv_config.lua`. If the category has no list, it falls back to `Locations`.
- Skill checks: `pipe` easy+easy, `pothole` easy, `streetlight` easy+medium, `electrical` medium+medium, `transformer` medium+hard, `hazmat` hard+hard. All other tasks use `SkillCheck.Difficulty`. The key is `SkillCheck.Input`.
- `traffic_control` opens an equipment menu instead of a progress bar. You can place cones, barriers, stop signs, slow signs and work lights (max 8), and pick up the nearest one. **Complete Setup** needs at least 4 props placed. Props are removed 60 seconds after completion.
- Some tasks show particle effects at the site (pipe, water main, gas leak, downed lines, electrical, transformer, hydrant, storm drain, hazmat).

### Pay, XP and ranks
- Pay per task = `Economy.BasePay` x rank `payMultiplier` x teamwork bonus, rounded down. Paid to the `Economy.Currency` account.
- XP per task = the task XP plus a random value from -5 to +10.
- A player ranks up when XP reaches `current rank x 1000` (rank 1 needs 1000, rank 2 needs 2000, and so on). The top rank is the highest key in `Config.Ranks`.
- Teamwork bonus: +10% for each other on-duty worker within 30 m, up to +30%. Workers get a notification when it changes.
- Scavenging: after each paid task there is a `ItemDrops.chance` percent chance to receive one weighted random item from `ItemDrops.items`.
- Stats (rank, XP, repairs, earnings) are saved to the database after each paid task, on clock-out and on disconnect.

### Sectors and the grid
- The map is split into sectors (`Config.Sectors`). Each sector has a health value from 0 to 100, saved to the database. Health is saved after changes and every 5 minutes.
- Every 10 minutes, if at least one worker is on duty, each sector loses `decayRate / 6` health. When health reaches `blackoutThreshold` or lower, every client gets a blackout alert and lights flicker for players inside that sector.
- Every 10 minutes, if nobody is on duty, any sector at or below its blackout threshold regains 2 health per tick, up to threshold + 15. Players are told the power is restored. Sectors above the threshold do not change.
- A completed task repairs the sector that contains the player by the task's repair value.
- The server also clears emergencies older than 30 minutes at that tick, when nobody is on duty.

### Emergencies
- Every 10 minutes (first check 5 minutes after start), while a worker is on duty, there is a 15% chance of a random emergency (`water_main`, `gas_leak`, `downed_lines` or `fallen_tree`) in a random sector with no active emergency. One emergency per sector.
- The location comes from `CategoryLocations.emergency`. If all are in use, it falls back to `Locations`, then to the sector centre.
- The sector loses twice the task's repair value, but never drops below `blackoutThreshold + 5`.
- Everyone gets a flashing red blip. On-duty workers also get a notification and a dialog to set a waypoint. Others get a simple city alert.
- When an on-duty worker comes within 80 m, the prop, particles and a "Respond" target zone appear.
- Responding needs the task's minimum rank. It is a 15 s progress bar, then a hard skill check (medium, hard, hard). You must be within 20 m of the emergency.
- Reward: `BasePay x 2` cash (paid to `Account` in `sv_config.lua`) and 1.5x the task XP. The sector regains the task's repair value.
- Weather: an on-duty client checks the weather every minute (10 minute cooldown per client). On rain, the server has a 30% chance to send a "storm drain" notice (5 minute server cooldown). On thunder, it has a 40% chance to trigger a `fallen_tree` or `downed_lines` emergency. The rain notice is a message only. It does not change pay.

### Foreman tools (rank 5)
- `/controlroom` opens a dashboard of sector health for on-duty rank 5 workers. It updates live while open. Each sector has a **Dispatch Crew** button that alerts all on-duty workers with a waypoint offer.
- Foremen can assign a task to another on-duty worker through the `AssignWorkerTask` server callback. This is a callback only. There is no menu or command for it in this resource.

### Sub-contractor companies
- A worker of rank 3 or higher registers a company at the boss ped (target option **Sub-Contractor Office**) or with `/company`. The fee is taken from bank first, then cash. Name length is 3 to 40 characters and must be unique. One company per player.
- The city keeps up to `maxOpenContracts` open contracts. Each is "complete N jobs in a sector". The budget is N x `budgetPerTask`.
- The owner accepts one contract at a time. One company per sector at a time. The contract must be done before the deadline.
- Only tasks completed by the owner or crew in that sector count. Notice: "Contract progress".
- On completion the budget goes into company funds and reputation rises. `employeeCut` of the budget is split among online crew and paid in cash.
- On expiry the company loses reputation (not below 0).
- The owner can hire the closest player within 5 m ("Hire Nearby Worker"), and withdraw company funds to `withdrawAccount`. Crew lists are kept in memory and reset when the resource restarts.

### Other
- `/reportdamage` logs damage to the database and lowers the sector health by 0.5. Cooldown 30 seconds.
- Exports (server): `GetSectorHealth`, `GetAllSectorHealth`, `TriggerBlackout`, `GetPlayerSeniority`, `RepairSector`, `TriggerEmergency`, `GetActiveEmergencies`, `ResolveEmergency`, plus bridge exports (`GetPlayer`, `GetIdentifier`, `GetCharacterName`, `AddMoney`, `RemoveMoney`, `GetMoney`, `AddItem`, `RemoveItem`, `HasItem`, `GetJobName`, `GetJobGrade`, `HasJob`, `IsOnDuty`).
- Exports (client): `IsPlayerOnDuty`, `GetNearestWorkZone`, `IsPlayerLoaded`, `GetPlayerJob`, `HasJob`, `IsOnDuty`.

## Commands

| Command | Who | What it does |
|---|---|---|
| `/workstatus` | Everyone | Shows rank, XP, and repair count. |
| `/controlroom` | Rank 5 on duty | Opens the Control Room. |
| `/company` | Everyone | Opens the sub-contractor company menu. |
| `/reportdamage [type]` | On duty | Reports damage at your position. Default type is `general`. |
| `/setsectorhealth <sector> <health>` | `group.admin` | Sets a sector's health (0 to 100). |
| `/triggeremergency <type> <sector>` | `group.admin` | Starts an emergency (`water_main`, `gas_leak`, `downed_lines`, `fallen_tree`). |

There are no key binds. All interaction is through ox_target.

## Prerequisites

- `ox_lib` (required, in the manifest).
- `oxmysql` (required, in the manifest).
- `ox_target`. The client uses it when it is started. If it is not, the code calls `qb-target`.
- A framework. Qbox (`qbx_core`) is detected first. The bridge reads player data through the `qb-core` export, which Qbox provides. `qb-core` and `es_extended` are also detected.
- Optional: `ox_inventory` (used for scavenged items when started, then `qs-inventory`, `codem-inventory`, then the framework inventory), a fuel script (`ox_fuel`, `LegacyFuel`, `ps-fuel`, `cdn-fuel`, `qs-fuelstations`, `lj-fuel`, `ti_fuel`, `myFuel`), and the `vehiclekeys:client:SetOwner` event for keys.

The code does not check a job name. Any player can clock in at the depot, so no job entry is needed in `qbx_core/shared/jobs.lua`. If you want to restrict it, add your own job check.

## Installation

1. Put the `dps-cityworker` folder in your resources folder.
2. Import `sql/cityworker.sql` into your database. It creates `city_worker_users`, `city_infrastructure`, `city_damage_reports`, `city_contractors` and `city_contracts`, and adds the three default sectors with health 100.
3. Add the resource to `server.cfg` after its dependencies:
   ```
   ensure ox_lib
   ensure oxmysql
   ensure ox_target
   ensure qbx_core
   ensure dps-cityworker
   ```
4. Make sure the scavenge items in `Config.ItemDrops.items` (default `copper`, `plastic`, `metalscrap`, `electronics`, `steel`) exist in your inventory. Change the list if they do not.
5. Admin commands use `restricted = 'group.admin'`. Give your admins that ACE group, for example:
   ```
   add_principal identifier.license:YOUR_LICENSE group.admin
   ```
6. Restart the server and check the console for `Framework Detected` and `Loaded sector health from database`.

## Configuration

Settings are in `config.lua` (shared) and `sv_config.lua` (server). Options marked "not used" are present in the file but not read by the code.

### config.lua: core

| Option | Default | Meaning |
|---|---|---|
| `Debug` | `false` | Extra console output for exploit warnings, item drops and detection. |
| `Framework` | `'auto'` | Not used. The framework is always auto-detected. |
| `Inventory` | `'auto'` | Not used. The inventory is always auto-detected. |
| `Target` | `'ox_target'` | Not used. ox_target is used when started, otherwise qb-target. |
| `Notify` | `'ox_lib'` | Client notifications. `'ox_lib'` uses ox_lib. Anything else uses the framework notify. |
| `FuelScript.enable` | `true` | If `false`, fuel is set with the `fuel` statebag only. |
| `FuelScript.script` | `'auto'` | `'auto'` finds the first started fuel script. Or name one. |
| `BossModel` | `` `s_m_y_construct_02` `` | Ped model of the boss. |
| `BossCoords` | `vec4(884.47, -2337.14, 29.34, 359.1)` | Depot. Boss ped, blip, clock-out spot (15 m) and the office ped. |
| `TaskCompleteDistance` | not in file (12.0) | Optional. Max distance to the task location when paid. |
| `EmergencyDistance` | not in file (20.0) | Optional. Max distance to resolve an emergency. |

### config.lua: Economy

| Option | Default | Meaning |
|---|---|---|
| `Economy.BasePay` | `250` | Base pay per task. Also the base of the emergency bonus (x2). |
| `Economy.Currency` | `'cash'` | Account paid for tasks. |
| `Economy.WeeklyBudget` | `50000` | Not used. |
| `Economy.CompanyRegistrationFee` | `5000` | Fee to register a company. |
| `Economy.MaterialCost` | `50` | Not used. |

### config.lua: ItemDrops

| Option | Default | Meaning |
|---|---|---|
| `ItemDrops.enabled` | `true` | Turns scavenging on or off. |
| `ItemDrops.chance` | `40` | Percent chance per paid task. |
| `ItemDrops.items` | see below | List of `{ name, min, max, chance }`. `chance` is a weight. |

Default items: `copper` 1-3 (50), `plastic` 1-4 (30), `metalscrap` 2-5 (30), `electronics` 1-1 (10), `steel` 1-2 (5).

### config.lua: Ranks

Each rank is `{ label, payMultiplier, canAssign }`. `canAssign` is not used. The Control Room check is hard-coded to rank 5. A new rank needs `rank x 1000` XP and a key in this table.

| Rank | Label | `payMultiplier` |
|---|---|---|
| 1 | Probationary Laborer | 1.0 |
| 2 | Junior Technician | 1.2 |
| 3 | Senior Technician | 1.5 |
| 4 | Specialist | 1.8 |
| 5 | Foreman | 2.5 |

### config.lua: Sectors

Each sector: `Sectors['id'] = { label, coords, radius, decayRate, blackoutThreshold }`.

| Field | Meaning |
|---|---|
| `label` | Name shown to players. |
| `coords` | Sector centre (vec3). |
| `radius` | Sector radius in metres. The first sector that contains the player is used. |
| `decayRate` | Health lost per hour while workers are on duty. |
| `blackoutThreshold` | Health at or below which the sector is in blackout. |

| Sector id | Label | Coords | Radius | `decayRate` | `blackoutThreshold` |
|---|---|---|---|---|---|
| `legion` | Legion Square | `vec3(188.0, -923.0, 30.0)` | 300.0 | 0.5 | 0 |
| `mirror_park` | Mirror Park | `vec3(1065.0, -716.0, 57.0)` | 400.0 | 0.3 | 0 |
| `sandy_shores` | Sandy Shores | `vec3(1863.0, 3704.0, 33.0)` | 600.0 | 0.8 | 10 |

New sectors get a database row at start. The Control Room page (`web/index.html`) has a card for each of the three default sector ids only. Add a card there for each new sector, with `id="sector-<id>"` and a `dispatchCrew('<id>')` button.

### config.lua: SkillCheck

| Option | Default | Meaning |
|---|---|---|
| `SkillCheck.Difficulty` | `{ 'easy', 'easy', 'medium' }` | Skill check sequence for tasks without their own sequence. |
| `SkillCheck.HardDifficulty` | `{ 'medium', 'medium', 'hard' }` | Not used. |
| `SkillCheck.Input` | `{'e'}` | Keys for the ox_lib skill check. |

### config.lua: TaskProps

Prop model for each task id. Defaults:

| Task | Prop |
|---|---|
| `pipe`, `water_main` | `prop_waterpump_01` |
| `pothole`, `manhole`, `traffic_control`, `bridge_inspection`, `utility_locating` | `prop_roadcone02a` |
| `meter_reading` | `prop_toolchest_05` |
| `graffiti` | `prop_cs_spray_can` |
| `trash` | `prop_rub_binbag_01` |
| `streetlight` | `prop_worklight_03b` |
| `hydrant` | `prop_fire_hydrant_2` |
| `sign_repair` | `prop_sign_road_01a` |
| `storm_drain` | `prop_barrier_work06a` |
| `electrical` | `prop_elecbox_01a` |
| `tree_trimming` | `prop_tree_stump_01` |
| `cable_install` | `prop_rail_boxpile` |
| `transformer` | `prop_sub_trans_01` |
| `hazmat` | `prop_barrel_01a` |
| `gas_leak` | `prop_barrel_02a` |
| `downed_lines` | `prop_worklight_03a` |
| `fallen_tree` | `prop_tree_fallen_02` |

A task with no entry uses `prop_roadcone02a`.

### config.lua: TrafficProps

| Key | Default |
|---|---|
| `Cone` | `prop_roadcone02a` |
| `Barrier` | `prop_barrier_work05` |
| `Sign_Stop` | `prop_sign_road_04b` |
| `Sign_Slow` | `prop_sign_road_04a` |
| `Light` | `prop_worklight_02a` |

### config.lua: TaskAnimations

Animation per task category (`dict` / `anim`).

| Category | Dict | Anim |
|---|---|---|
| `maintenance` | `amb@world_human_welding@male@base` | `base` |
| `road` | `amb@world_human_const_drill@male@drill@base` | `base` |
| `electrical` | `anim@heists@prison_heiststation@cop_reactions` | `yourface` |
| `cleanup` | `timetable@floyd@clean_kitchen@base` | `base` |
| `utility` | `amb@world_human_clipboard@male@base` | `base` |
| `sewer` | `mini@repair` | `fixing_a_ped` |
| `emergency` | `amb@world_human_welding@male@base` | `base` |

### config.lua: Emergency

The Emergency table is not read by the code. The values are fixed in the server code: 15% chance per 10 minute check, XP x1.5, pay `BasePay x 2`, one per sector.

| Option | Default | Meaning |
|---|---|---|
| `Emergency.RandomChance` | `15` | Not used (fixed at 15). |
| `Emergency.BonusMultiplier` | `1.5` | Not used (fixed at 1.5). |
| `Emergency.PaymentMultiplier` | `2.0` | Not used (fixed at 2). |
| `Emergency.MaxActivePerSector` | `1` | Not used (fixed at 1). |

### config.lua: Contractor

| Option | Default | Meaning |
|---|---|---|
| `Contractor.enable` | `true` | Turns the company system on or off. |
| `Contractor.minRankToRegister` | `3` | Minimum rank to register a company. |
| `Contractor.maxOpenContracts` | `3` | Open contracts the city keeps. |
| `Contractor.contractDeadline` | `3600` | Seconds to finish an accepted contract. |
| `Contractor.targetTasksRange` | `{ 5, 12 }` | Min and max jobs for a new contract. |
| `Contractor.budgetPerTask` | `400` | Contract budget = jobs x this. |
| `Contractor.reputationPerContract` | `10` | Reputation gained on completion. |
| `Contractor.reputationOnExpire` | `5` | Reputation lost on expiry. |
| `Contractor.employeeCut` | `0.15` | Share of the budget split among online crew. |
| `Contractor.withdrawAccount` | `'bank'` | Account that receives withdrawals. |
| `Contractor.bossPed` | `true` | Spawns an office ped at `BossCoords` with a target option. |

### sv_config.lua

| Option | Default | Meaning |
|---|---|---|
| `Timeout` | `5000` | Not used. |
| `Account` | `'cash'` | Account for the emergency bonus. Task pay uses `Economy.Currency`. |
| `Vehicle` | `` `bison` `` | Work truck model. |
| `VehicleSpawn` | `vec4(892.6, -2339.76, 30.39, 262.64)` | Truck spawn position and heading. |
| `Locations` | 20 vec3 points | Fallback task and emergency locations. |
| `CategoryLocations` | see below | Task locations by category. |
| `BridgeLocations` | 3 entries | Not used. |
| `TrafficControlZones` | 4 entries | Not used. |
| `MeterRoutes` | 3 routes | Not used. |

`CategoryLocations` keys and default point counts: `maintenance` 7, `road` 7, `electrical` 7, `cleanup` 7, `utility` 7, `sewer` 7, `emergency` 6. Add points as `vec3(x, y, z)`. Use ground-level Z.

## Troubleshooting

- **Console shows `WARNING: No supported framework detected!`**: Start `qbx_core` (or `qb-core`, `es_extended`) before this resource. Money, items and names do not work without one.
- **`Database not ready after 20s` in the console**: `oxmysql` was not connected within 20 seconds. Start `oxmysql` first and check its connection string. Sector health then starts at 100.
- **Queries fail or stats never save**: The SQL was not imported. Run `sql/cityworker.sql`.
- **No boss ped at the depot**: The ped spawns when you are within 50 m of `BossCoords`. Check that `ox_target` is started and the coordinates are correct for your map.
- **"Could not start work" or no truck**: You are already clocked in on the server (for example after a client crash). Clock out at the depot, or reconnect to reset it. Also check `Vehicle` is a valid model and `VehicleSpawn` is free.
- **Truck has no fuel or no keys**: Fuel is set through the first started fuel script. Set `FuelScript.script` to your script. Keys use the `vehiclekeys:client:SetOwner` event, so your keys script must handle it.
- **Paid nothing, "Something went wrong"**: You must stand within 12 m of the task location, and at least 2 seconds must pass between completions. Also check that `Economy.Currency` is a valid account for your framework.
- **Scavenged items never appear**: The item names in `ItemDrops.items` must exist in your inventory. If not, the add fails silently.
- **Control Room does not open**: It needs rank 5 and an on-duty shift. Players below rank 5 get "Only Foremen can access the Control Room".
- **A new sector is missing in the Control Room**: Add its card in `web/index.html` (see Sectors).
- **Cannot register a company**: Needs rank 3 (`minRankToRegister`), the fee in bank or cash, a unique name of 3 to 40 characters, and no existing company.
- **Crew does not progress a contract**: Hired crew only count for tasks done in the contract's sector. Crew lists are lost on resource restart, so hire them again.
- **Admin commands do nothing**: The caller needs the `group.admin` ACE.
