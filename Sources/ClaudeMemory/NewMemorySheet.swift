import MemoryCore
import SwiftUI

struct NewMemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ClaudeProject
    let onCreated: (URL) -> Void

    @State private var slug = ""
    @State private var title = ""
    @State private var description = ""
    @State private var type = MemoryType.project
    @State private var memoryBody = ""
    @State private var error: String?

    private var slugProblem: MemoryError? {
        slug.isEmpty ? nil : model.repository.slugProblem(slug, in: project)
    }

    private var canCreate: Bool {
        !slug.isEmpty && slugProblem == nil && !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What is still missing before Create turns on, so a dimmed button is never a mystery.
    private var missingHint: String? {
        if slug.isEmpty { return "Enter a name to create the memory." }
        if slugProblem != nil { return nil }
        if description.trimmingCharacters(in: .whitespaces).isEmpty { return "Add a description so Claude knows when to read it." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New memory in \(project.displayName)")
                .font(.headline)

            Form {
                TextField("Name", text: $slug, prompt: Text("kebab-case-slug"))
                    .onChange(of: slug) { error = nil }
                TextField("Title", text: $title, prompt: Text(slug.isEmpty ? "Shown in MEMORY.md" : slug))
                TextField("Description", text: $description, prompt: Text("One line Claude uses to decide when to read it"), axis: .vertical)
                    .lineLimit(1...3)
                Picker("Type", selection: $type) {
                    ForEach(MemoryType.allCases, id: \.self) { Text($0.rawValue) }
                }
                LabeledContent("Content") {
                    TextEditor(text: $memoryBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                }
            }

            if let message = slugProblem?.errorDescription ?? error {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let missingHint {
                Text(missingHint)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Spacing.l)
        .frame(width: 560)
    }

    private func create() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        do {
            let url = try model.createMemory(
                in: project,
                slug: slug,
                title: trimmedTitle.isEmpty ? slug : trimmedTitle,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type,
                body: memoryBody)
            onCreated(url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
