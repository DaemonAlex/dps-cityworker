## Randolio: City Worker

**ESX/QB supported with bridge.**

Requirements: https://github.com/overextended/ox_lib/releases

**Changes** - Last updated: 10/03/2024

* Added support for both ESX and QB frameworks.
* Utilized ox lib throughout.
* Configs are now split into client and server configs. (config.lua and sv_config.lua)
* The whole script was rewritten to secure any exploits.

**You have permission to use this in your server and edit for your personal needs but are not allowed to redistribute.**

## 🚀 Future Feature Improvements (Roadmap)

We are planning to expand `randol_cityworker` from a simple task script into a comprehensive career simulation. Below are the planned features:

### 💥 Dynamic Failure System (The "Oh No!" Factor)
- **Skill Checks:** replacing simple progress bars with `lib.skillCheck`.
    - **Critical Failure:** Failing a check can result in pipes bursting (water particle effects) or fuse boxes sparking (player damage/electrocution).
    - **Risk vs. Reward:** Harder tasks offer higher payouts but carry significant injury risks, requiring bandages or EMS assistance.
- **Emergency Callouts:** Rare "Code Red" events (e.g., massive water main break) that trigger for all workers, offering triple pay for immediate response.

### 🛠️ Immersive Props & Scene Setup
- **Tool Requirement:** Players must purchase and carry a **Toolbox** item from a hardware store to start shifts.
- **Physicality:** Forced animations for carrying heavy tools/ladders from the truck to the work site.
- **Work Zone Safety:** Requirement to place **Traffic Cones** or **Road Barriers** (via context menu) around the site before work can commence. Failure to do so increases the risk of NPC traffic accidents.

### 📈 Career Progression & Specialization
- **Tiered Contracts:** Replace the single job with a progression system:
    - **Tier 1:** Sanitation & Debris Cleanup (Low risk).
    - **Tier 2:** Road Crew (Pothole repair, tarmac laying).
    - **Tier 3:** Electrician (High voltage, rubber gloves required).
    - **Tier 4:** Infrastructure Specialist (Emergency response).
- **Unlockables:** Higher tiers unlock better company vehicles and specialized tools.

### 🤝 Co-op "Buddy System"
- **Multi-Role Jobs:** High-tier jobs designed for two players.
    - *Example:* One player operates the bucket truck arm (driver) while the second player performs repairs in the bucket (spotter).
- **Group Pay:** Form a work crew to receive "Efficiency Bonuses" and shared mission payouts.

### 🌍 "Living City" Impact
- **Real-Time Consequences:** Fixing an electrical box triggers `SetArtificialLightsState` to actually turn streetlights back on in the area.
- **Visual Feedback:** Successful repairs result in visible changes (lights turning on, smoke stopping), providing "Hero Moments" for workers.
