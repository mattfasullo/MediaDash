import SwiftUI
import AppKit

/// A text view that supports text selection and can report selected text
struct SelectableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    @Binding var selectedText: String?
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        
        // Configure text view
        textView.string = text
        textView.font = font
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        
        // Configure scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        // Store references
        context.coordinator.textView = textView
        context.coordinator.selectedTextBinding = $selectedText
        
        // Set up selection monitoring using coordinator method
        context.coordinator.setupObserver(for: textView)
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            // Update text if it changed
            if textView.string != text {
                textView.string = text
            }
            
            // Update font if needed
            if textView.font != font {
                textView.font = font
            }
            
            // Update binding reference
            context.coordinator.selectedTextBinding = $selectedText
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        weak var textView: NSTextView?
        var selectedTextBinding: Binding<String?>?
        // Store textView reference for observer cleanup
        private weak var observedTextView: NSTextView?
        
        func setupObserver(for textView: NSTextView) {
            // Remove existing observer if any (safe to call even if observer was already removed)
            if let oldTextView = observedTextView, oldTextView !== textView {
                Foundation.NotificationCenter.default.removeObserver(
                    self,
                    name: NSTextView.didChangeSelectionNotification,
                    object: oldTextView
                )
            }
            
            // Store reference to textView for cleanup
            observedTextView = textView
            
            // Add new observer (target-action pattern doesn't return a value)
            Foundation.NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: textView
            )
        }
        
        @objc func selectionChanged(_ notification: NSNotification) {
            guard let textView = textView,
                  let binding = selectedTextBinding else { return }
            
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let selected = (textView.string as NSString).substring(with: selectedRange)
                binding.wrappedValue = selected
            } else {
                binding.wrappedValue = nil
            }
        }
        
        deinit {
            // Remove observer when coordinator is deallocated
            // Safe to call even if textView is nil or deallocated - NotificationCenter handles this gracefully
            Foundation.NotificationCenter.default.removeObserver(
                self,
                name: NSTextView.didChangeSelectionNotification,
                object: observedTextView
            )
        }
    }
}

