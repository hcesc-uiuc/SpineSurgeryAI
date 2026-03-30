//
//  SurveyConfig.swift
//  SensingApp
//
//  Created by Samir Kurudi on 2/13/26.
//

import Foundation

enum QuestionType {
    case text
    case singleChoice([String])
    case multiChoice([String])
    case scale(Int, Int)
}

struct SurveyQuestion: Identifiable {
    let id: String
    let question: String
    let type: QuestionType
}

struct SurveyConfig {
    
    static let questions: [SurveyQuestion] = [

        SurveyQuestion(
            id: "pain_level",
            question: "What is your current pain level?",
            type: .scale(0, 10)
        ),

        SurveyQuestion(
            id: "mobility",
            question: "How would you rate your mobility today?",
            type: .singleChoice(["Excellent", "Good", "Fair", "Poor"])
        ),

        SurveyQuestion(
            id: "numbness",
            question: "Are you experiencing numbness or tingling?",
            type: .multiChoice([
                "No numbness",
                "Hands",
                "Feet",
                "Arms",
                "Legs",
                "Other"
            ])
        ),

        SurveyQuestion(
            id: "notes",
            question: "Any additional comments?",
            type: .text
        )
    ]
}
