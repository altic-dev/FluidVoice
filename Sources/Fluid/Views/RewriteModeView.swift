import SwiftUI

struct RewriteModeView: View {
    @ObservedObject var service: RewriteModeService
    @ObservedObject var asr: ASRService
    @EnvironmentObject var menuBarManager: MenuBarManager
    var onClose: (() -> Void)?
    
    @State private var inputText: String = ""
    @State private var showOriginal: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "pencil.and.outline")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Rewrite Mode")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Original Text Section
                    if !service.originalText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Original Text")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !service.rewrittenText.isEmpty {
                                    Button(showOriginal ? "Hide" : "Show") {
                                        withAnimation { showOriginal.toggle() }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.link)
                                }
                            }
                            
                            if showOriginal {
                                Text(service.originalText)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "text.cursor")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("No text selected")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Select text in any app and press the Rewrite shortcut to speak your rewrite instruction")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    
                    // Rewritten Text Section
                    if !service.rewrittenText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rewritten Text")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.green)
                            
                            Text(service.rewrittenText)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                            
                            HStack {
                                Button("Try Again") {
                                    service.rewrittenText = ""
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                                
                                Button("Replace Original") {
                                    service.acceptRewrite()
                                    onClose?()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                            .padding(.top, 8)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    
                    // Conversation History (optional, maybe just last error)
                    if let lastMsg = service.conversationHistory.last, lastMsg.role == .assistant, service.rewrittenText.isEmpty {
                        Text(lastMsg.content) // Error message usually
                            .foregroundStyle(.red)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Input Area
            HStack {
                TextField("How should I rewrite this? (e.g. 'Make it professional')", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitRequest)
                
                Button(action: submitRequest) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || service.isProcessing || service.originalText.isEmpty)
                
                // Voice Input
                Button(action: toggleRecording) {
                    Image(systemName: asr.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(asr.isRunning ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(service.originalText.isEmpty)
                
                if service.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: asr.finalText) { newText in
            if !newText.isEmpty {
                inputText = newText
            }
        }
        .onExitCommand {
            onClose?()
        }
        .onAppear {
            // Set overlay mode to rewrite when this view appears
            menuBarManager.setOverlayMode(.rewrite)
        }
        .onDisappear {
            // Reset overlay mode to dictation when leaving
            menuBarManager.setOverlayMode(.dictation)
        }
    }
    
    private func toggleRecording() {
        if asr.isRunning {
            Task { await asr.stop() }
        } else {
            asr.start()
        }
    }
    
    private func submitRequest() {
        guard !inputText.isEmpty else { return }
        let prompt = inputText
        inputText = ""
        Task {
            await service.processRewriteRequest(prompt)
        }
    }
}
