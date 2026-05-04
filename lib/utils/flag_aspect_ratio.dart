const defaultFlagAspectRatio = 4 / 3;

double flagAspectRatioForCountryCode(String? countryCode) =>
    defaultFlagAspectRatio;

double flagWidthForCountryCode(String? countryCode, double height) =>
    height * flagAspectRatioForCountryCode(countryCode);
