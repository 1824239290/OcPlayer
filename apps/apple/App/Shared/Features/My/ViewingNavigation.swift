/// Shared labels and symbol variants for the viewing dashboard's navigation entry.
enum ViewingNavigation {
    static let title = "观影"
    static let pageTitle = "观影空间"
    static let symbol = "play.rectangle.on.rectangle"
    static let selectedSymbol = "play.rectangle.on.rectangle.fill"

    static func symbol(isSelected: Bool) -> String {
        isSelected ? selectedSymbol : symbol
    }
}
