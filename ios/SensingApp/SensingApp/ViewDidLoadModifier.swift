//
//  ViewDidLoadModifier.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//

import SwiftUI

struct ViewDidLoadModifier: ViewModifier {
    @State private var didLoad = false
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content.onAppear {
            if !didLoad {
                didLoad = true
                action?()
            }
        }
    }
}

extension View {
    func onLoad(_ perform: (() -> Void)? = nil) -> some View {
        modifier(ViewDidLoadModifier(action: perform))
    }
}
