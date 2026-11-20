return {
    -- Account the pay goes to when Config.Economy.Currency is not set
    Account = 'cash',

    -- The work truck model
    Vehicle = `bison`,

    -- Where the truck comes out, until an admin stands on the spot and runs
    -- /cityspot truck. Work sites are not listed here any more: every site is
    -- captured in game with /cityspot and kept in the city_work_sites table.
    VehicleSpawn = vec4(892.6, -2339.76, 30.39, 262.64),
}
