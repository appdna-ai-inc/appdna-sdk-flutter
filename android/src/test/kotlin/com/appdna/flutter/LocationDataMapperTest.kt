package com.appdna.flutter

import ai.appdna.sdk.onboarding.LocationData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The location answer's provenance ids cross the method channel. `getLocationData` returns the native `LocationData`
 * through `locationDataToMap`, a hand-written key list (internal so this test can call it): a key left out never
 * reaches Dart, and `flutter test` mocks the channel away. Red control: remove `mapbox_id` from the mapper and the
 * first test fails.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LocationDataMapperTest {
    private val plugin = AppdnaPlugin()

    @Test
    fun aResolvedAnswerCarriesItsProvenanceIds() {
        val out = plugin.locationDataToMap(LocationData(formatted_address = "Porto, Porto, Portugal", city = "Porto", raw_query = "port", mapbox_id = "dXJuOm1ieHBsYzpwcm9iZQ", place_id = "probe-place-id"))
        assertEquals("dXJuOm1ieHBsYzpwcm9iZQ", out["mapbox_id"])
        assertEquals("probe-place-id", out["place_id"])
    }

    @Test
    fun aTypedAnswerCarriesThemAsNull() {
        val out = plugin.locationDataToMap(LocationData(formatted_address = "porto", raw_query = "porto"))
        assertNull(out["mapbox_id"])
        assertNull(out["place_id"])
    }
}
