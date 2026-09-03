import Foundation

enum ItemTemplates {
    static func login(
        url: String = "",
        username: String = "",
        password: String = "",
        totpSecret: String? = nil
    ) -> ItemPayload {
        var fields = [
            ItemField(label: "Username", value: username, type: .text),
            ItemField(label: "Password", value: password, type: .password, isConcealed: true),
            ItemField(label: "URL", value: url, type: .url),
        ]
        if let totp = totpSecret {
            fields.append(ItemField(label: "One-Time Password", value: totp, type: .totp))
        }
        return ItemPayload(fields: fields)
    }

    static func creditCard(
        cardholderName: String = "",
        number: String = "",
        expiryDate: String = "",
        cvv: String = "",
        pin: String = ""
    ) -> ItemPayload {
        ItemPayload(fields: [
            ItemField(label: "Cardholder Name", value: cardholderName),
            ItemField(label: "Card Number", value: number, type: .creditCardNumber, isConcealed: true),
            ItemField(label: "Expiry Date", value: expiryDate, type: .monthYear),
            ItemField(label: "CVV", value: cvv, type: .password, isConcealed: true),
            ItemField(label: "PIN", value: pin, type: .password, isConcealed: true),
        ])
    }

    static func identity(
        firstName: String = "",
        lastName: String = "",
        email: String = "",
        phone: String = "",
        address: String = ""
    ) -> ItemPayload {
        ItemPayload(fields: [
            ItemField(label: "First Name", value: firstName),
            ItemField(label: "Last Name", value: lastName),
            ItemField(label: "Email", value: email, type: .email),
            ItemField(label: "Phone", value: phone, type: .phone),
            ItemField(label: "Address", value: address),
        ])
    }

    static func secureNote(content: String = "") -> ItemPayload {
        ItemPayload(fields: [], notes: content)
    }
}
