import Foundation
import SwiftUI
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkDraftBindingTests {
    private func model() -> PNNetworkModel {
        PNNetworkModel(defaults: UserDefaults(suiteName: "DynamicPhotoWall.NetworkDraft.Tests.\(UUID())")!,
            settings: { WallSettings() }, displays: { [] }, folders: { [] }, albums: { [] }, assets: { [] },
            enter: {}, sharedSettings: { _ in })
    }
    private func wall() -> PNSnapshot {
        let a = UUID(), b = UUID(), group = UUID()
        return PNSnapshot(wallId: UUID(), sessionId: UUID(), leaderId: a, revision: 0,
            groups: [PNGroup(id: group, name: "Group")], displays: [
                PNDisplay(key: PNDisplayKey(peerId: a, displayId: "1"), selected: true, groupId: group, x: 0, y: 0, width: 1920, height: 1080),
                PNDisplay(key: PNDisplayKey(peerId: b, displayId: "1"), selected: false, groupId: group, x: 1920, y: 0, width: 1920, height: 1080),
                PNDisplay(key: PNDisplayKey(peerId: b, displayId: "2"), selected: true, groupId: nil, x: 3840, y: 0, width: 1920, height: 1080)
            ], sources: [], playback: PNOptions(values: [:]))
    }
    @Test func retainedControlSurvivesShortenedOrEmptyDisplayList() throws {
        let model = model(), original = wall()
        model.draft = original
        let display = original.displays[2]
        let position = model.displayBinding(display, wallId: original.wallId, \.x)
        let selection = model.displayBinding(display, wallId: original.wallId, \.selected)
        model.draft?.displays.removeLast(2)
        #expect(position.wrappedValue == display.x)
        #expect(selection.wrappedValue == display.selected)
        let shortened = model.draft
        position.wrappedValue = -100; selection.wrappedValue = false
        #expect(model.draft == shortened)
        model.draft?.displays.removeAll()
        #expect(position.wrappedValue == display.x)
        position.wrappedValue = 400
        #expect(model.draft?.displays.isEmpty == true)
    }
    @Test func bindingsFollowPeerAndDisplayIdentityThroughReorderingAndReplacement() throws {
        let model = model(), original = wall()
        model.draft = original
        let a = model.displayBinding(original.displays[0], wallId: original.wallId, \.x)
        let b = model.displayBinding(original.displays[1], wallId: original.wallId, \.x)
        let membership = model.displayBinding(original.displays[1], wallId: original.wallId, \.groupId)
        model.draft?.displays.reverse()
        a.wrappedValue = -1920; b.wrappedValue = 2000; membership.wrappedValue = nil
        let current = try #require(model.draft)
        #expect(current.displays.first { $0.key == original.displays[0].key }?.x == -1920)
        #expect(current.displays.first { $0.key == original.displays[1].key }?.x == 2000)
        #expect(current.displays.first { $0.key == original.displays[1].key }?.groupId == nil)
        #expect(current.displays.first { $0.key == original.displays[2].key } == original.displays[2])
        model.draft?.displays = [original.displays[1], original.displays[0]]
        #expect(a.wrappedValue == 0 && b.wrappedValue == 1920)
    }
    @Test func retainedControlsDoNotRecreateClearedDraftOrEditAnotherWall() {
        let model = model(), original = wall()
        model.draft = original
        let binding = model.displayBinding(original.displays[0], wallId: original.wallId, \.selected)
        model.reload() // Clearing a draft is the same invalidation as the crash path.
        #expect(binding.wrappedValue)
        binding.wrappedValue = false
        #expect(model.draft == nil)
        var other = original; other.wallId = UUID(); model.draft = other
        binding.wrappedValue = false
        model.addGroup(wallId: original.wallId)
        model.removeGroup(original.groups[0].id, wallId: original.wallId)
        #expect(model.draft == other)
    }
    @Test func groupDeletionUsesCurrentMembersIncludingUnselectedDisplays() throws {
        let model = model(), original = wall()
        model.draft = original
        let group = original.groups[0].id
        let membership = model.displayBinding(original.displays[1], wallId: original.wallId, \.groupId)
        model.draft?.displays = [original.displays[1]]
        model.removeGroup(group, wallId: original.wallId)
        let current = try #require(model.draft)
        #expect(current.groups.isEmpty && current.displays.count == 1)
        #expect(current.displays[0].groupId == nil)
        #expect(!current.displays[0].selected && current.displays[0].x == 1920)
        #expect(membership.wrappedValue == nil)
        model.removeGroup(group, wallId: original.wallId)
        #expect(model.draft == current)
        model.draft = nil
        model.removeGroup(group, wallId: original.wallId)
        #expect(model.draft == nil)
    }
}
