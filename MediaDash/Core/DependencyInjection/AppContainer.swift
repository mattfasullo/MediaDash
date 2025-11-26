import Foundation

/// Simple dependency injection container
@MainActor
class AppContainer {
    static let shared = AppContainer()
    
    private var dependencies: [String: Any] = [:]
    
    private init() {}
    
    /// Register a dependency
    func register<T>(_ dependency: T, for type: T.Type) {
        let key = String(describing: type)
        dependencies[key] = dependency
    }
    
    /// Resolve a dependency
    func resolve<T>(_ type: T.Type) -> T? {
        let key = String(describing: type)
        return dependencies[key] as? T
    }
    
    /// Clear all dependencies (useful for testing)
    func clear() {
        dependencies.removeAll()
    }
}

