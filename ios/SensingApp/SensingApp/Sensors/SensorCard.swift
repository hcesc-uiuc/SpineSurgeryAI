//
//  SensorCard.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 2/24/26.
//

import SwiftUI

//
// MARK: - Reusable Sensor Card
//
struct SensorCard<Content: View>: View {

    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundColor(.illiniBlue)

            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.illiniBlue.opacity(0.25), lineWidth: 1)
                )
        )
        .shadow(radius: 2)
    }
}
