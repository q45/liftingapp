// ExerciseLibrary.swift
// Preset exercise list and goal definitions

import Foundation

struct ExerciseTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: String
}

struct GoalOption: Identifiable {
    let id: String
    let label: String
    let desc: String
}

let exerciseLibrary: [ExerciseTemplate] = [
    // Chest
    ExerciseTemplate(name: "Bench Press",       category: "Chest"),
    ExerciseTemplate(name: "Incline Bench",      category: "Chest"),
    ExerciseTemplate(name: "Dumbbell Fly",       category: "Chest"),
    ExerciseTemplate(name: "Cable Fly",          category: "Chest"),
    ExerciseTemplate(name: "Push-Up",            category: "Chest"),
    // Back
    ExerciseTemplate(name: "Deadlift",           category: "Back"),
    ExerciseTemplate(name: "Pull-Up",            category: "Back"),
    ExerciseTemplate(name: "Barbell Row",        category: "Back"),
    ExerciseTemplate(name: "Lat Pulldown",       category: "Back"),
    ExerciseTemplate(name: "Seated Row",         category: "Back"),
    // Legs
    ExerciseTemplate(name: "Back Squat",         category: "Legs"),
    ExerciseTemplate(name: "Romanian Deadlift",  category: "Legs"),
    ExerciseTemplate(name: "Leg Press",          category: "Legs"),
    ExerciseTemplate(name: "Lunges",             category: "Legs"),
    ExerciseTemplate(name: "Leg Curl",           category: "Legs"),
    ExerciseTemplate(name: "Leg Extension",      category: "Legs"),
    // Shoulders
    ExerciseTemplate(name: "Overhead Press",     category: "Shoulders"),
    ExerciseTemplate(name: "Lateral Raise",      category: "Shoulders"),
    ExerciseTemplate(name: "Front Raise",        category: "Shoulders"),
    ExerciseTemplate(name: "Face Pull",          category: "Shoulders"),
    // Arms
    ExerciseTemplate(name: "Bicep Curl",         category: "Arms"),
    ExerciseTemplate(name: "Hammer Curl",        category: "Arms"),
    ExerciseTemplate(name: "Tricep Pushdown",    category: "Arms"),
    ExerciseTemplate(name: "Skull Crusher",      category: "Arms"),
    // Core
    ExerciseTemplate(name: "Plank",              category: "Core"),
    ExerciseTemplate(name: "Ab Wheel",           category: "Core"),
    ExerciseTemplate(name: "Russian Twist",      category: "Core"),
    ExerciseTemplate(name: "Cable Crunch",       category: "Core"),
]

let goalOptions: [GoalOption] = [
    GoalOption(id: "stronger",  label: "Get Stronger",  desc: "Low reps, heavy weight, long rest"),
    GoalOption(id: "bigger",    label: "Build Muscle",  desc: "Moderate weight, high volume"),
    GoalOption(id: "leaner",    label: "Get Leaner",    desc: "Higher reps, short rest, circuits"),
    GoalOption(id: "endurance", label: "Endurance",     desc: "Light weight, very high reps"),
]

let categories = ["All", "Chest", "Back", "Legs", "Shoulders", "Arms", "Core"]
