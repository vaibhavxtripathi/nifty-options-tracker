import 'dart:convert';
import 'dart:io';

/// Fetches the raw instrument master.
///
/// Split out from the repository behind an interface so a test can supply
/// 590 fixture contracts — and can count how many times a fetch happened,
/// which is how "second launch uses cache with no network call" becomes an
/// assertion rather than an observation.
abstract interface class InstrumentMasterClient {
  /// The raw JSON body. ~32.5 MB in production, so callers must not hold it
  /// beyond handing it to the parser.
  Future<String> fetch();
}

/// The live endpoint (§3.2). Unauthenticated: no broker session is needed,
/// which is why contract search works outside market hours and before the
/// broker subsystem exists at all.
final class AngelInstrumentMasterClient implements InstrumentMasterClient {
  const AngelInstrumentMasterClient();

  static const String url =
      'https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json';

  @override
  Future<String> fetch() async {
    // dart:io rather than package:http: this is the exact call Phase 0 step 2
    // already proved against this endpoint, and Phase 3's WebSocket is dart:io
    // too, so the data layer stays on one networking stack.
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
