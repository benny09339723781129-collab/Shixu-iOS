#import <Foundation/Foundation.h>

/// Opt-in Debug-only read-only checks of actual public Nasdaq/TWSE providers.
/// --market-source-smoke is required; --ui-fixtures always disables the checks.
FOUNDATION_EXPORT void SXRunMarketSourceChecks(void);
