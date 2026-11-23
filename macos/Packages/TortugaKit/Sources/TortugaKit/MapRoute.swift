import Foundation

/// What the route map draws for a state: the trunk from this Mac to the guard,
/// and each routed app's tail through its middle to its exit. Places come from
/// the countries Tor reports; a country the map doesn't know is skipped.
/// Outside Tor mode there are no routes: everything is empty and the whole
/// world shows.
public struct MapRoute: Sendable, Equatable {
    public struct Tail: Sendable, Equatable, Identifiable {
        public var app: AppID
        /// The guard, or the Mac without one.
        public var start: Coordinate?
        public var middle: Coordinate?
        public var exit: Coordinate?
        public var colorIndex: Int
        /// How far to spread the middle's ring and the exit's dot from their
        /// country's place (AppColor.offset). Depends on the other apps in
        /// that country: one counter per country, shared by middles and exits,
        /// counted in app-identifier order. It starts at 1 in the guard's and
        /// the Mac's countries, so a dot never sits on their rings.
        public var middleSlot: Int
        public var exitSlot: Int
        public var id: String { app.id }

        /// Start, middle, exit: the known ones, in order.
        public var points: [Coordinate] { [start, middle, exit].compactMap { $0 } }
    }

    public var mac: Coordinate?
    public var guardPlace: Coordinate?
    public var bridge: BridgeKind?
    public var tails: [Tail]

    /// `region`: the Mac's region code (Locale.current.region), if any.
    public init(state: EngineState, region: String?, map: WorldMap = .shared) {
        bridge = state.trunk.bridge
        guard state.mode == .tor else {
            mac = nil
            guardPlace = nil
            tails = []
            return
        }
        let mac = region.flatMap(map.place(country:))
        let guardCountry = state.trunk.guardRelay?.country
        let guardPlace = guardCountry.flatMap(map.place(country:))
        self.mac = mac
        self.guardPlace = guardPlace

        var taken: [String: Int] = [:]
        if mac != nil, let region { taken[region.uppercased()] = 1 }
        if guardPlace != nil, let guardCountry { taken[guardCountry.uppercased()] = 1 }
        func place(_ country: String) -> (Coordinate?, slot: Int) {
            guard let p = map.place(country: country) else { return (nil, 0) }
            let code = country.uppercased()
            let slot = taken[code, default: 0]
            taken[code] = slot + 1
            return (p, slot)
        }

        tails = state.apps
            .filter { !state.exceptions.contains($0.app) }
            .sorted { $0.app.id < $1.app.id }
            .map { route in
                let middle = place(route.middle.country)
                let exit = place(route.exit.country)
                return Tail(app: route.app, start: guardPlace ?? mac, middle: middle.0, exit: exit.0,
                            colorIndex: AppColor.index(for: route.app.id),
                            middleSlot: middle.slot, exitSlot: exit.slot)
            }
    }

    /// Every place drawn, for fitting the map to them. Empty (the whole world)
    /// until there is a guard or a middle or exit to show.
    public var places: [Coordinate] {
        let route = [guardPlace].compactMap { $0 } + tails.flatMap { [$0.middle, $0.exit].compactMap { $0 } }
        return route.isEmpty ? [] : [mac].compactMap { $0 } + route
    }
}
