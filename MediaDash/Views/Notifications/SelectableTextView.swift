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
        
        // Set up selection monitoring
        Foundation.NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        
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
    }
}

