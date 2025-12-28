//
//  NanoBeeTests.swift
//  NanoBeeTests
//
//  Created by Stanley Benoit on 12/26/25.
//

import XCTest
@testable import NanoBee

final class NanoBeeTests: XCTestCase {

    func testAppBuildsAndLinks() {
        XCTAssertTrue(true)
    }

    func testSerialManagerCanBeCreated() {
        let sm = SerialManager()
        XCTAssertNotNil(sm)
    }
}

