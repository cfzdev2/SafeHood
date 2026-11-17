import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'local_camera_connection.dart';

const onvifDeviceNamespace = 'http://www.onvif.org/ver10/device/wsdl';
const onvifMediaNamespace = 'http://www.onvif.org/ver10/media/wsdl';
const onvifMedia2Namespace = 'http://www.onvif.org/ver20/media/wsdl';
const onvifSchemaNamespace = 'http://www.onvif.org/ver10/schema';

Iterable<XmlElement> onvifElements(XmlNode? xml, String name) =>
    xml?.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == name,
    ) ??
    const [];
XmlElement? onvifChild(XmlElement? xml, String name) =>
    xml?.childElements.where((e) => e.name.local == name).firstOrNull;
String? onvifText(XmlNode? xml, String name) =>
    onvifElements(xml, name).firstOrNull?.innerText.trim();

String onvifEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

class OnvifSoapResult {
  const OnvifSoapResult(this.status, this.xml);

  final int status;
  final XmlDocument? xml;

  XmlElement? get fault => onvifElements(xml, 'Fault').firstOrNull;
  bool get ok => status >= 200 && status < 300 && xml != null && fault == null;
  bool get requiresLogin =>
      status == 401 ||
      status == 403 ||
      onvifElements(fault, 'Value').any(
        (e) => const {
          'notauthorized',
          'failedauthentication',
          'invalidsecurity',
        }.contains(e.innerText.trim().split(':').last.toLowerCase()),
      );

  XmlElement? response(String operation) =>
      ok ? onvifElements(xml, '${operation}Response').firstOrNull : null;
}

/// Keeps requests (and credentials) on the selected camera. Camera-advertised
/// hostnames/IPs are not followed; some firmware returns a stale address.
class OnvifSoapClient {
  OnvifSoapClient(this.host, {this.login});

  final String host;
  final CameraLogin? login;
  Duration _clockOffset = Duration.zero;

  void updateCameraClock(XmlElement? dateTimeResponse) {
    final utc = onvifElements(dateTimeResponse, 'UTCDateTime').firstOrNull;
    if (utc == null) return;
    int? read(String field) => int.tryParse(onvifText(utc, field) ?? '');
    final values = [
      for (final name in ['Year', 'Month', 'Day', 'Hour', 'Minute', 'Second'])
        read(name),
    ];
    if (values.any((value) => value == null)) return;
    final cameraTime = DateTime.utc(
      values[0]!,
      values[1]!,
      values[2]!,
      values[3]!,
      values[4]!,
      values[5]!,
    );
    final offset = cameraTime.difference(DateTime.now().toUtc());
    if (offset.abs() > const Duration(minutes: 1)) _clockOffset = offset;
  }

  Future<OnvifSoapResult> call(
    Uri endpoint,
    String namespace,
    String operation, {
    String body = '',
    Duration timeout = const Duration(seconds: 4),
    bool authenticated = true,
    bool sensitive = false,
  }) {
    final xml =
        '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:o="$namespace" xmlns:tt="$onvifSchemaNamespace">
<s:Body><o:$operation>$body</o:$operation></s:Body>
</s:Envelope>''';
    return postEnvelope(
      endpoint,
      xml,
      action: '$namespace/$operation',
      timeout: timeout,
      authenticated: authenticated,
      sensitive: sensitive,
    );
  }

  Future<OnvifSoapResult> postEnvelope(
    Uri endpoint,
    String envelope, {
    String? action,
    Duration timeout = const Duration(seconds: 5),
    bool authenticated = true,
    bool sensitive = false,
  }) async {
    if (!isCameraLanHost(host) ||
        endpoint.host.toLowerCase() != host.toLowerCase() ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.userInfo.isNotEmpty) {
      throw const CameraConnectionIssue(
        'Adres usługi ONVIF nie należy do kamery.',
      );
    }

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    // Device certificates are often self-signed. Only permit this for
    // unauthenticated reads; never send credentials or Wi-Fi keys under it.
    final account = authenticated ? login : null;
    if (account == null && !sensitive) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    Future<(OnvifSoapResult, List<String>)> send({
      String? authorization,
    }) async {
      final payload = account == null
          ? envelope
          : _withUsernameToken(envelope, account);
      final bytes = utf8.encode(payload);
      final request = await client.postUrl(endpoint);
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/soap+xml; charset=utf-8${action == null ? '' : '; action="$action"'}',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'SafeHood/1.0');
      if (authorization != null) {
        request.headers.set(HttpHeaders.authorizationHeader, authorization);
      }
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final body = <int>[];
      await for (final chunk in response) {
        if (body.length + chunk.length > 512 * 1024) {
          throw const CameraConnectionIssue('Odpowiedź ONVIF jest za duża.');
        }
        body.addAll(chunk);
      }
      XmlDocument? xml;
      try {
        xml = XmlDocument.parse(utf8.decode(body, allowMalformed: true));
      } on XmlParserException {
        // Some cameras return an HTML error or an empty body.
      }
      return (
        OnvifSoapResult(response.statusCode, xml),
        response.headers[HttpHeaders.wwwAuthenticateHeader] ?? const [],
      );
    }

    try {
      return await (() async {
        final (initial, challenge) = await send();
        if (initial.status != 401 || account == null) return initial;
        // Dart's automatic HTTP auth retries POST without replaying the body.
        // Retry explicitly so the camera receives the complete SOAP envelope.
        final authorization = _httpAuthorization(challenge, endpoint, account);
        if (authorization == null) return initial;
        final (retry, _) = await send(authorization: authorization);
        return retry;
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  String _withUsernameToken(String envelope, CameraLogin account) {
    final random = Random.secure();
    final nonce = List<int>.generate(20, (_) => random.nextInt(256));
    final created = DateTime.now().toUtc().add(_clockOffset).toIso8601String();
    final digest = base64.encode(
      sha1.convert([
        ...nonce,
        ...utf8.encode(created),
        ...utf8.encode(account.password),
      ]).bytes,
    );
    const securityNs =
        'http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-wssecurity-secext-1.0.xsd';
    const utilityNs =
        'http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-wssecurity-utility-1.0.xsd';
    const profileNs =
        'http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-username-token-profile-1.0';
    const soapNs =
        'http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-soap-message-security-1.0';
    final security =
        '''<wsse:Security xmlns:wsse="$securityNs" xmlns:wsu="$utilityNs">
<wsse:UsernameToken><wsse:Username>${onvifEscape(account.username)}</wsse:Username>
<wsse:Password Type="$profileNs#PasswordDigest">$digest</wsse:Password>
<wsse:Nonce EncodingType="$soapNs#Base64Binary">${base64.encode(nonce)}</wsse:Nonce>
<wsu:Created>$created</wsu:Created></wsse:UsernameToken></wsse:Security>''';
    if (envelope.contains('</s:Header>')) {
      return envelope.replaceFirst('</s:Header>', '$security</s:Header>');
    }
    return envelope.replaceFirst(
      '<s:Body>',
      '<s:Header>$security</s:Header><s:Body>',
    );
  }
}

String? _httpAuthorization(
  List<String> headers,
  Uri endpoint,
  CameraLogin account,
) {
  for (final header in headers) {
    if (!header.toLowerCase().startsWith('digest ')) continue;
    final entries = RegExp(r'(\w+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))');
    final params = {
      for (final m in entries.allMatches(header.substring(7)))
        m[1]!.toLowerCase(): (m[2] ?? m[3]!).replaceAllMapped(
          RegExp(r'\\(.)'),
          (escape) => escape[1]!,
        ),
    };
    final realm = params['realm'];
    final nonce = params['nonce'];
    final qop = params['qop'];
    final supportsAuth =
        qop?.split(',').any((v) => v.trim().toLowerCase() == 'auth') ?? false;
    if (realm == null ||
        nonce == null ||
        (qop != null && !supportsAuth) ||
        params['userhash'] == 'true') {
      continue;
    }

    final algorithm = (params['algorithm'] ?? 'MD5').toUpperCase();
    final hash = switch (algorithm) {
      'MD5' || 'MD5-SESS' => md5,
      'SHA-256' || 'SHA-256-SESS' => sha256,
      _ => null,
    };
    if (hash == null) continue;
    String digest(String value) => hash.convert(utf8.encode(value)).toString();
    String quote(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

    final path = endpoint.path.isEmpty ? '/' : endpoint.path;
    final resource = endpoint.hasQuery ? '$path?${endpoint.query}' : path;
    final random = Random.secure();
    final cnonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    var ha1 = digest('${account.username}:$realm:${account.password}');
    if (algorithm.endsWith('-SESS')) ha1 = digest('$ha1:$nonce:$cnonce');
    final ha2 = digest('POST:$resource');
    const count = '00000001';
    final answer = digest(
      supportsAuth
          ? '$ha1:$nonce:$count:$cnonce:auth:$ha2'
          : '$ha1:$nonce:$ha2',
    );
    final fields = [
      'username=${quote(account.username)}',
      'realm=${quote(realm)}',
      'nonce=${quote(nonce)}',
      'uri=${quote(resource)}',
      'algorithm=$algorithm',
      'response=${quote(answer)}',
      if (supportsAuth) ...['qop=auth', 'nc=$count'],
      if (supportsAuth || algorithm.endsWith('-SESS'))
        'cnonce=${quote(cnonce)}',
      if (params['opaque'] case final String value) 'opaque=${quote(value)}',
    ];
    return 'Digest ${fields.join(', ')}';
  }
  if (headers.any((header) => header.toLowerCase().startsWith('basic ')) &&
      !account.username.contains(':')) {
    final encoded = base64.encode(
      utf8.encode('${account.username}:${account.password}'),
    );
    return 'Basic $encoded';
  }
  return null;
}
