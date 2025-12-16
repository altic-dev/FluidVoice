//
//  AppServices.swift
//  Fluid
//
//  Centralized service container to reduce SwiftUI view type complexity.
//  By holding heavy services here (outside ContentView's @StateObject declarations),
//  we reduce the generic type signature of ContentView, which helps avoid
//  Swift runtime type metadata crashes at app launch.
//

import Foundation
import Combine

/// Centralized container for app-wide services.
/// This exists to reduce ContentView's generic type signature complexity,
/// which has been observed to cause EXC_BAD_ACCESS crashes during Swift
/// runtime type metadata resolution at app launch.
@MainActor
final class AppServices: ObservableObject {
    /// Shared singleton instance
    static let shared = AppServices()
    
    /// Audio hardware observation service
    let audioObserver = AudioHardwareObserver()
    
    /// Automatic speech recognition service
    let asr = ASRService()
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Services are created but NOT started here.
        // Actual initialization (CoreAudio listeners, model loading) is deferred
        // to when the UI is ready, via AudioStartupGate.
        
        // CRITICAL: Forward changes from child services to this container.
        // This allows ContentView to observe 'AppServices' (which is metadata-safe)
        // instead of observing 'ASRService' directly (which causes metadata crashes),
        // while still triggering UI updates when transcription or audio state changes.
        
        audioObserver.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        asr.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
