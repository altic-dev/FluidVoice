import Foundation

/// Each dictation key is shown as one package: the key and the cleanup style it dictates with.
/// Storage keeps two kinds of keys: main keys, which share one style, and one optional key per
/// style. Changing a package's style moves its key between the two without touching other keys.
struct DictationShortcutRouting<Key: Equatable, Style: Equatable> {
    enum Source: Equatable {
        case main(index: Int)
        case style
    }

    struct Package: Equatable {
        let key: Key
        let style: Style
        let source: Source
    }

    enum Blocker: Equatable {
        /// Another key already dictates with that style.
        case taken(by: Key)
        /// This key can only be a main key, such as a mouse button.
        case mainKeysOnly
    }

    var mainKeys: [Key]
    var mainStyle: Style
    /// Styles that own a key, in display order.
    var styleKeys: [(style: Style, key: Key)]
    /// False for keys that only main dictation accepts, such as mouse buttons.
    let keyCanMoveToStyle: (Key) -> Bool

    var packages: [Package] {
        self.mainKeys.enumerated().map { Package(key: $1, style: self.mainStyle, source: .main(index: $0)) }
            + self.styleKeys.map { Package(key: $0.key, style: $0.style, source: .style) }
    }

    func blocker(moving package: Package, to style: Style) -> Blocker? {
        if style == package.style { return nil }
        if case .main = package.source, self.mainKeys.count == 1 { return nil }
        if case .style = package.source, style == self.mainStyle { return nil }
        guard self.keyCanMoveToStyle(package.key) else { return .mainKeysOnly }
        if let owner = self.styleKeys.first(where: { $0.style == style }) { return .taken(by: owner.key) }
        return nil
    }

    /// Returns false and changes nothing when the move is blocked.
    @discardableResult
    mutating func move(_ package: Package, to style: Style) -> Bool {
        guard style != package.style, self.blocker(moving: package, to: style) == nil else { return false }
        switch package.source {
        case let .main(index):
            guard self.mainKeys.indices.contains(index), self.mainKeys[index] == package.key else { return false }
            if self.mainKeys.count == 1 {
                self.mainStyle = style
            } else {
                self.mainKeys.remove(at: index)
                self.styleKeys.append((style, package.key))
            }
        case .style:
            guard let index = self.styleKeys.firstIndex(where: { $0.key == package.key && $0.style == package.style }) else { return false }
            self.styleKeys.remove(at: index)
            if style == self.mainStyle {
                self.mainKeys.append(package.key)
            } else {
                self.styleKeys.insert((style, package.key), at: index)
            }
        }
        return true
    }
}
