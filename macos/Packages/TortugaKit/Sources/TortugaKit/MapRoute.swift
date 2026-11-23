import Foundation

/// What the route map draws for a state: the trunk from this Mac to the guard,
/// and each routed app's tail through its middle to its exit. Places come from
/// the countries Tor reports; a country the map doesn't know is skipped.
public struct MapRoute: Sendable, Equatable {
    public struct Tail: Sendable, Equatable, Identifiable {
        public var app: AppID
        /// Guard (or the Mac, without one), middle, exit: the known ones.
        public var points: [Coordinate]
        public var exit: Coordinate?
        public var colorIndex: Int
        /// 0 for the first app (by identifier) whose exit is in that country,
        /// then 1, 2…: how far to spread its dot (AppColor.offset).
        public var exitSlot: Int
        public var id: String { app.id }
    }

    public var mac: Coordinate?
    public var guardPlace: Coordinate?
    public var bridge: BridgeKind?
    public var tails: [Tail]

    /// `region`: the Mac's region code (Locale.current.region), if any.
    public init(state: EngineState, region: String?, map: WorldMap = .shared) {
        mac = region.flatMap(map.place(country:))
        guardPlace = state.trunk.guardRelay.flatMap { map.place(country: $0.country) }
        bridge = state.trunk.bridge
        let start = guardPlace ?? mac
        let routed = state.apps
            .filter { !state.exceptions.contains($0.app) }
            .sorted { $0.app.id < $1.app.id }
        var taken: [String: Int] = [:]
        tails = routed.map { route in
            let exitCode = route.exit.country.uppercased()
            let slot = taken[exitCode, default: 0]
            taken[exitCode] = slot + 1
            let middle = map.place(country: route.middle.country)
            let exit = map.place(country: route.exit.country)
            return Tail(app: route.app, points: [start, middle, exit].compactMap { $0 }, exit: exit,
                        colorIndex: AppColor.index(for: route.app.id), exitSlot: slot)
        }
    }

    /// Every place drawn, for fitting the map to them.
    public var places: [Coordinate] {
        [mac, guardPlace].compactMap { $0 } + tails.flatMap(\.points)
    }
}
