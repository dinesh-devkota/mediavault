# Verify compiled output, not just preprocessor spelling. Both objects use the
# same Relay.cpp; only the isolated fixture target may contain this logger.
file(STRINGS "${PRODUCTION}" production_strings REGEX "MV_FIXTURE_RELAY_V1|writeFixtureRelayTrace")
if(production_strings)
  message(FATAL_ERROR "Fixture relay diagnostics leaked into production code")
endif()
file(STRINGS "${FIXTURE}" fixture_strings REGEX "MV_FIXTURE_RELAY_V1")
if(NOT fixture_strings)
  message(FATAL_ERROR "The fixture relay logger was not compiled")
endif()
