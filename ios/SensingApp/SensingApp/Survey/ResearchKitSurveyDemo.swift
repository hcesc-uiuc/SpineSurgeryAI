//
//  ResearchKitSurveyDemo.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/19/25.
//


import ResearchKit
import SwiftUI
import ResearchKitSwiftUI


struct ResearchKitSurveyDemo: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        ResearchForm(
            id: "SurveyTask",
            steps: {
                ResearchFormStep(
                    title: "Demographics",
                    subtitle: "Tell us about yourself",
                    content: {
                        TextQuestion(
                            id: "Q1",
                            title: "What is your name?",
                            prompt: "Enter your name here",
                            lineLimit: .singleLine,
                            characterLimit: 0
                        )
                        .questionRequired(true)
                    }
                )
                ResearchFormStep(
                    title: "Yes or no question",
                    subtitle: "Tell us about yourself",
                    content: {
                        MultipleChoiceQuestion(
                            id: "Q2",
                            title: "What is your name?",
                            choices: [
                                TextChoice(
                                    id: "Q21",
                                    choiceText: "Yes",
                                    value: 1
                                ),
                                TextChoice(
                                    id: "Q22",
                                    choiceText: "No",
                                    value: 0
                                )
                            ], choiceSelectionLimit: .single
                        )
                        .questionRequired(true)
                    }
                )
            },
            onResearchFormCompletion: { completion in
                switch completion {
                    case .completed(let results):
                        let resultsAsText = results.compactMap { result in
                            "\(result.identifier): \(getAnswerValue(answer: result.answer))"
                        }
                        print(resultsAsText)
                        self.isPresented = false
                    case .discarded:
                        print("cancelled")
                    default:
                        print("cancelled")
                }
            }
        )
    }
    
    
    /// Converts an ReserachKit `AnswerFormat` value into a human-readable `String` representation.
    ///
    /// This function inspects the specific case of the `AnswerFormat` enum and extracts
    /// its associated value, converting it to a standardized string format.
    ///
    /// - Parameter answer: The `AnswerFormat` enum value containing the user’s response.
    /// - Returns: A `String` that represents the underlying value in a readable format.
    ///            If the value is `nil` or cannot be parsed, a fallback string is returned.
    func getAnswerValue(answer: AnswerFormat) -> String {

        // Use a switch to handle each possible AnswerFormat case
        switch answer {

            // MARK: - Text Response
            case .text(let value):
                // Return the string or "nil" if the optional is empty
                return value ?? "nil"

            // MARK: - Numeric Response
            case .numeric(let value):
                // Convert the number to string, fallback to -1
                return String(value ?? -1)

            // MARK: - Multiple Choice Response
            case .multipleChoice(let values):
                // If values is nil, return an explicit message
                guard let vals = values else {
                    return "Multiple choice is nil."
                }

                // Convert each ResultValue to a string
                var choices: [String] = []
                for val in vals {
                    switch val {
                        case .int(let value):
                            // Convert integer choice
                            choices.append(String(value))
                        case .string(let value):
                            // Append string choice directly
                            choices.append(value)
                        case .date(let value):
                            // Convert the date using helper function
                            choices.append(dateToString(value))
                        default:
                            // Any unsupported type results in "nil"
                            return "nil"
                    }
                }

                // Join all choices into a comma-separated list
                return choices.joined(separator: ", ")

            // MARK: - Scale (Likert or slider)
            case .scale(let value):
                return String(value ?? -1)

            // MARK: - Date
            case .date(let value):
                // Convert date or fallback to current date
                return dateToString(value ?? Date())

            // MARK: - Fallback for unsupported / future cases
            default:
                return "nil"
        }
    }
    
    
    
    /// Converts an optional `Date` into a formatted string.
    ///
    /// If the provided date is `nil`, the function returns `"Invalid Date"`.
    /// The output format defaults to `"yyyy-MM-dd HH:mm:ss"` but can be customized.
    /// The formatter uses the user's current timezone and locale.
    ///
    /// - Parameters:
    ///   - date: An optional `Date` to format.
    ///   - format: A string specifying the desired date format (default is `"yyyy-MM-dd HH:mm:ss"`).
    /// - Returns: A formatted date string, or `"Invalid Date"` if the input was `nil`.
    func dateToString(_ date: Date?, format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        
        // Return early if date is nil
        guard let date = date else {
            return "Invalid Date"
        }
        
        // Create a new formatter for date formatting
        let formatter = DateFormatter()
        formatter.dateFormat = format              // Desired date format
        formatter.timeZone = .current              // Use the device's current timezone
        formatter.locale = .current                // Use the device's locale (12/24h, language, etc.)
        
        // Format and return the date string
        return formatter.string(from: date)
    }
}



/// For preview purposes.
struct ResearchKitSurveyDemo_Previews: PreviewProvider {
    static var previews: some View {
        ResearchKitSurveyDemo(isPresented: .constant(true))
    }
}

//#Preview {
//    ResearchKitSurveyDemo_Previews()
//}
