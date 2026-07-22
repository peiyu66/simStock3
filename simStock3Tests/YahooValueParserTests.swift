import XCTest
@testable import simStock3

final class YahooValueParserTests: XCTestCase {
    func testParsesYahooHTMLNumber() {
        let html = #"<span class="Fw(600)">2,410.50</span></li>"#

        XCTAssertEqual(
            YahooValueParser.price(html, strippingHTML: true),
            2_410.50
        )
    }

    func testFindsQuoteValuesByLabelInsteadOfColumnPosition() {
        let html = """
        <li class="price-detail-item"><span>成交</span><span class="Fw(600)">2,430</span></li>
        <li class="price-detail-item"><span>漲跌幅</span><span><span>▲</span>0.83%</span></li>
        <li class="price-detail-item"><span>總量</span><span class="Fw(600)">4,760</span></li>
        """

        XCTAssertEqual(YahooValueParser.labeledValue("成交", inHTML: html), "2,430")
        XCTAssertEqual(YahooValueParser.labeledValue("總量", inHTML: html), "4,760")
        XCTAssertNil(YahooValueParser.labeledValue("最低", inHTML: html))
    }

    func testRejectsNonFiniteAndNonPositivePrices() {
        XCTAssertNil(YahooValueParser.price("inf"))
        XCTAssertNil(YahooValueParser.price("-inf"))
        XCTAssertNil(YahooValueParser.price("nan"))
        XCTAssertNil(YahooValueParser.price("0"))
        XCTAssertNil(YahooValueParser.price("-1"))
    }

    func testVolumeAllowsZeroButRejectsInvalidValues() {
        XCTAssertEqual(YahooValueParser.volume("0"), 0)
        XCTAssertEqual(YahooValueParser.volume("29,874"), 29_874)
        XCTAssertNil(YahooValueParser.volume("inf"))
        XCTAssertNil(YahooValueParser.volume("-1"))
    }
}
