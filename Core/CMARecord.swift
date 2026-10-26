import Foundation

// Raw Cleveland Museum of Art Open Access API records.
//
// Verified against the live API (October 2026):
//  - image `width`/`height`/`filesize` are JSON *strings* ("3400"), not numbers.
//  - `images.annotation` is usually null but sometimes a string, so `images` is not a
//    homogeneous dictionary.
//  - `creators` is often an empty array (ancient and decorative works); `culture` is an array.
//  - `description` and `did_you_know` contain HTML (`<em>`, `<br>`, `<a>`).
// Every field is decoded leniently: a wrong type becomes nil instead of failing the record.

struct CMAListResponse: Decodable {
    struct Info: Decodable {
        var total: Int?
    }

    var info: Info?
    /// Records that could not be decoded at all are kept as nil so one malformed
    /// record never takes down a whole page.
    var data: [CMARecord?]

    private enum CodingKeys: String, CodingKey { case info, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try? c.decodeIfPresent(Info.self, forKey: .info)
        var items: [CMARecord?] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .data) {
            while !array.isAtEnd {
                if let record = try? array.decode(CMARecord.self) {
                    items.append(record)
                } else {
                    items.append(nil)
                    // Skip the undecodable element so iteration can continue.
                    _ = try? array.decode(AnyDecodable.self)
                }
            }
        }
        data = items
    }
}

/// Consumes any JSON value. Used to step over malformed array elements.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

/// An integer the API may encode as a number or a numeric string.
struct LenientInt: Decodable, Hashable {
    var value: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self), d.isFinite {
            value = Int(d)
        } else if let s = try? c.decode(String.self) {
            value = Int(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

struct CMAImage: Decodable, Hashable {
    var url: String?
    var width: Int?
    var height: Int?
    var filesize: Int?

    private enum CodingKeys: String, CodingKey { case url, width, height, filesize }

    init(url: String?, width: Int?, height: Int?, filesize: Int?) {
        self.url = url
        self.width = width
        self.height = height
        self.filesize = filesize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        width = (try? c.decodeIfPresent(LenientInt.self, forKey: .width))?.value
        height = (try? c.decodeIfPresent(LenientInt.self, forKey: .height))?.value
        filesize = (try? c.decodeIfPresent(LenientInt.self, forKey: .filesize))?.value
    }
}

struct CMAImages: Decodable, Hashable {
    var web: CMAImage?
    var print: CMAImage?
    var full: CMAImage?

    private enum CodingKeys: String, CodingKey { case web, print, full }

    init(web: CMAImage? = nil, print: CMAImage? = nil, full: CMAImage? = nil) {
        self.web = web
        self.print = print
        self.full = full
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        web = try? c.decodeIfPresent(CMAImage.self, forKey: .web)
        print = try? c.decodeIfPresent(CMAImage.self, forKey: .print)
        full = try? c.decodeIfPresent(CMAImage.self, forKey: .full)
    }
}

struct CMACreator: Decodable, Hashable {
    var description: String?
    var role: String?

    private enum CodingKeys: String, CodingKey { case description, role }

    init(description: String?, role: String?) {
        self.description = description
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
    }
}

struct CMARecord: Decodable, Hashable {
    var id: Int
    var accessionNumber: String?
    var shareLicenseStatus: String?
    var isHighlight: Bool?
    var title: String?
    var tombstone: String?
    var creationDate: String?
    var creators: [CMACreator]
    var culture: [String]
    var technique: String?
    var type: String?
    var department: String?
    var creditline: String?
    var url: String?
    var description: String?
    var artlensDescription: String?
    var didYouKnow: String?
    var images: CMAImages?

    private enum CodingKeys: String, CodingKey {
        case id
        case accessionNumber = "accession_number"
        case shareLicenseStatus = "share_license_status"
        case isHighlight = "is_highlight"
        case title, tombstone
        case creationDate = "creation_date"
        case creators, culture, technique, type, department, creditline, url, description
        case artlensDescription = "artlens_description"
        case didYouKnow = "did_you_know"
        case images
    }

    init(id: Int,
         accessionNumber: String? = nil,
         shareLicenseStatus: String? = nil,
         isHighlight: Bool? = nil,
         title: String? = nil,
         tombstone: String? = nil,
         creationDate: String? = nil,
         creators: [CMACreator] = [],
         culture: [String] = [],
         technique: String? = nil,
         type: String? = nil,
         department: String? = nil,
         creditline: String? = nil,
         url: String? = nil,
         description: String? = nil,
         artlensDescription: String? = nil,
         didYouKnow: String? = nil,
         images: CMAImages? = nil) {
        self.id = id
        self.accessionNumber = accessionNumber
        self.shareLicenseStatus = shareLicenseStatus
        self.isHighlight = isHighlight
        self.title = title
        self.tombstone = tombstone
        self.creationDate = creationDate
        self.creators = creators
        self.culture = culture
        self.technique = technique
        self.type = type
        self.department = department
        self.creditline = creditline
        self.url = url
        self.description = description
        self.artlensDescription = artlensDescription
        self.didYouKnow = didYouKnow
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the only field a record cannot exist without.
        guard let id = (try? c.decode(LenientInt.self, forKey: .id))?.value else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing artwork id")
        }
        self.id = id
        func string(_ key: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
            return nil
        }
        accessionNumber = string(.accessionNumber)
        shareLicenseStatus = string(.shareLicenseStatus)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .isHighlight) {
            isHighlight = b
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .isHighlight) {
            isHighlight = i != 0
        } else {
            isHighlight = nil
        }
        title = string(.title)
        tombstone = string(.tombstone)
        creationDate = string(.creationDate)
        creators = (try? c.decodeIfPresent([CMACreator].self, forKey: .creators)) ?? []
        if let list = try? c.decodeIfPresent([String].self, forKey: .culture) {
            culture = list
        } else if let single = string(.culture) {
            culture = [single]
        } else {
            culture = []
        }
        technique = string(.technique)
        type = string(.type)
        department = string(.department)
        creditline = string(.creditline)
        url = string(.url)
        description = string(.description)
        artlensDescription = string(.artlensDescription)
        didYouKnow = string(.didYouKnow)
        images = try? c.decodeIfPresent(CMAImages.self, forKey: .images)
    }

    func rawText(for field: MuseumText.Field) -> String? {
        switch field {
        case .description: return description
        case .artlensDescription: return artlensDescription
        case .didYouKnow: return didYouKnow
        }
    }
}
