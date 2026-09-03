import Testing
@testable import OnePasshole

struct FieldPathTests {
    @Test func parseSingleBracket() {
        let path = FieldPath.parse("user[email]")
        #expect(path?.group == "user")
        #expect(path?.leaf == "email")
    }

    @Test func parseNestedBrackets() {
        let path = FieldPath.parse("data[pvpnetaccount][name]")
        #expect(path?.group == "data[pvpnetaccount]")
        #expect(path?.leaf == "name")
    }

    @Test func parseIgnoresOrdinaryLabels() {
        #expect(FieldPath.parse("username") == nil)
        #expect(FieldPath.parse("commit") == nil)
        #expect(FieldPath.parse("One-Time Password") == nil)
        #expect(FieldPath.parse("[email]") == nil)
        #expect(FieldPath.parse("user[]") == nil)
    }

    @Test func displayLabelUsesLeafAndHumanizesUnderscores() {
        #expect(ItemField(label: "user[email]", value: "a").displayLabel == "email")
        #expect(ItemField(label: "data[pvpnetaccount][name]", value: "a").displayLabel == "name")
        #expect(ItemField(label: "data[pvpnetaccount][date_of_birth_month]", value: "01").displayLabel == "date of birth month")
        #expect(ItemField(label: "username", value: "a").displayLabel == "username")
    }

    @Test func groupingSplitsNestedRunsFromUngroupedFields() {
        let fields = [
            ItemField(label: "user[email]", value: "a"),
            ItemField(label: "user[password]", value: "b", type: .password, isConcealed: true),
            ItemField(label: "user[password_confirmation]", value: "c", type: .password, isConcealed: true),
            ItemField(label: "commit", value: "Register"),
        ]
        let groups = FieldPath.groups(from: fields)
        #expect(groups.count == 2)
        #expect(groups[0].title == "user")
        #expect(groups[0].fields.map(\.displayLabel) == ["email", "password", "password confirmation"])
        #expect(groups[1].title == nil)
        #expect(groups[1].fields.map(\.label) == ["commit"])
        // Original names are still on the fields — grouping must not rewrite them.
        #expect(groups[0].fields.map(\.label) == ["user[email]", "user[password]", "user[password_confirmation]"])
    }

    @Test func groupingKeepsSeparatePrefixesInTheirOwnGroups() {
        let fields = [
            ItemField(label: "data[pvpnetaccount][name]", value: "a"),
            ItemField(label: "data[pvpnetaccount][realm]", value: "na"),
            ItemField(label: "user[email]", value: "b"),
        ]
        let groups = FieldPath.groups(from: fields)
        #expect(groups.map(\.title) == ["data[pvpnetaccount]", "user"])
        #expect(groups[0].fields.map(\.displayLabel) == ["name", "realm"])
        #expect(groups[1].fields.map(\.displayLabel) == ["email"])
    }

    @Test func groupHeaderOnlyOnFirstFieldOfARun() {
        let fields = [
            ItemField(label: "user[email]", value: "a"),
            ItemField(label: "user[password]", value: "b"),
            ItemField(label: "commit", value: "Register"),
        ]
        #expect(FieldPath.groupHeader(at: 0, in: fields) == "user")
        #expect(FieldPath.groupHeader(at: 1, in: fields) == nil)
        #expect(FieldPath.groupHeader(at: 2, in: fields) == nil)
    }
}
