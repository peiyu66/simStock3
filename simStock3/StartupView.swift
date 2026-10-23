//
//  StartupView.swift
//  simStock3
//

import SwiftUI
import SwiftData
import UIKit

/// Defers the data-backed root until the lightweight launch artwork has entered
/// the window. The root replaces it in one SwiftUI update, without a fade or an
/// artificial minimum display duration. Required downloads/rebuilds still run
/// in the normal root and use its existing bottom progress strip.
struct SimStockStartupView: View {
    let modelContainer: ModelContainer
    @State private var presentsRoot = false

    var body: some View {
        if presentsRoot {
            SimStockRootView(modelContainer: modelContainer)
        } else {
            StartupArtworkView {
                presentsRoot = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

/// Uses the same full-bounds aspect-fit UIImageView as LaunchScreen.storyboard.
/// The approved bitmap includes its own white canvas; no separate text, crop,
/// safe-area scaling, or dark-mode variant can change the adopted layout.
struct StartupArtworkView: UIViewControllerRepresentable {
    var onPresented: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> StartupArtworkController {
        StartupArtworkController(onPresented: onPresented)
    }

    func updateUIViewController(_ controller: StartupArtworkController, context: Context) {
        controller.onPresented = onPresented
    }

    static func dismantleUIViewController(_ controller: StartupArtworkController, coordinator: ()) {
        controller.onPresented = nil
    }
}

final class StartupArtworkController: UIViewController {
    var onPresented: (() -> Void)?
    private var hasScheduledRoot = false

    init(onPresented: (() -> Void)?) {
        self.onPresented = onPresented
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(onPresented:)")
    }

    override func loadView() {
        let artwork = UIImageView(image: UIImage(named: "LaunchArtwork"))
        artwork.backgroundColor = .white
        artwork.contentMode = .scaleAspectFit
        artwork.isAccessibilityElement = true
        artwork.accessibilityLabel = "小確幸股票模擬機"
        artwork.accessibilityIdentifier = "startup-artwork"
        view = artwork
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasScheduledRoot, onPresented != nil else { return }
        hasScheduledRoot = true

        // Return from the appearance/layout callbacks before constructing the
        // root's StateObject and query views. This schedules work, not a timer;
        // actual submitted-frame timing is verified with launch recordings.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.viewIfLoaded?.window != nil else {
                self.hasScheduledRoot = false
                return
            }
            self.onPresented?()
        }
    }
}
