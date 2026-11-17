'use strict';

const {
  resolveDeviceServiceUrl,
} = require('./onvif_camera_session');

const MEDIA_V1 = 'http://www.onvif.org/ver10/media/wsdl';
const MEDIA_V2 = 'http://www.onvif.org/ver20/media/wsdl';

const GET_CAPABILITIES_SOAP = `
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
 <s:Body>
  <tds:GetCapabilities>
   <tds:Category>All</tds:Category>
  </tds:GetCapabilities>
 </s:Body>
</s:Envelope>`;

const GET_PROFILES_SOAP = `
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
 <s:Body>
  <trt:GetProfiles/>
 </s:Body>
</s:Envelope>`;

const GET_SERVICES_SOAP = `
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
 <s:Body><tds:GetServices>
  <tds:IncludeCapability>false</tds:IncludeCapability>
 </tds:GetServices></s:Body>
</s:Envelope>`;

function decodeXmlText(value) {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, '\'')
    .replace(/&amp;/g, '&');
}

function escapeXmlText(value) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function extractElementBody(
  xml,
  elementName,
) {
  const expression =
    new RegExp(
      `<(?:[\\w-]+:)?${elementName}\\b[^>]*>` +
      `([\\s\\S]*?)` +
      `</(?:[\\w-]+:)?${elementName}>`,
      'i',
    );

  return expression
    .exec(xml)?.[1] ?? null;
}

function extractElementText(
  xml,
  elementName,
) {
  const body =
    extractElementBody(
      xml,
      elementName,
    );

  if (body == null) {
    return null;
  }

  const value =
    decodeXmlText(
      body.trim(),
    );

  return value || null;
}

function extractMediaServiceUrl(xml) {
  const mediaBody =
    extractElementBody(
      xml,
      'Media',
    );

  if (!mediaBody) {
    return null;
  }

  return extractElementText(
    mediaBody,
    'XAddr',
  );
}

function extractProfileTokens(xml) {
  return [...new Set(Array.from(
    xml.matchAll(/<(?:[\w-]+:)?Profiles\b[^>]*\btoken\s*=\s*["']([^"']+)["']/gi),
    match => decodeXmlText(match[1].trim()),
  ).filter(Boolean))].slice(0, 4);
}

function buildGetStreamUriSoap(profileToken, mediaNamespace, tcp) {
  const token = escapeXmlText(profileToken);
  const setup = mediaNamespace === MEDIA_V2
    ? `<trt:Protocol>${tcp ? 'RTSP' : 'RtspUnicast'}</trt:Protocol>`
    : `<trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>
       <tt:Transport><tt:Protocol>${tcp ? 'RTSP' : 'UDP'}</tt:Protocol></tt:Transport>
       </trt:StreamSetup>`;

  return `
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:trt="${mediaNamespace}" xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body><trt:GetStreamUri>${setup}
  <trt:ProfileToken>${token}</trt:ProfileToken>
 </trt:GetStreamUri></s:Body>
</s:Envelope>`;
}

function parseHttpEndpoint(
  value,
  baseUrl,
  label,
) {
  let endpoint;

  try {
    endpoint =
      new URL(
        value,
        baseUrl,
      );
  } catch (_) {
    throw new Error(
      `${label} ma nieprawidłowy adres.`,
    );
  }

  if (
    endpoint.protocol !== 'http:' &&
    endpoint.protocol !== 'https:'
  ) {
    throw new Error(
      `${label} ma nieobsługiwany protokół.`,
    );
  }

  endpoint.hostname = baseUrl.hostname;
  endpoint.username = '';
  endpoint.password = '';
  endpoint.hash = '';
  return endpoint;
}

function parseStreamUri(value, deviceEndpoint) {
  let streamUri;

  try {
    streamUri =
      new URL(value);
  } catch (_) {
    throw new Error(
      'Kamera zwróciła nieprawidłowy Stream URI.',
    );
  }

  if (
    streamUri.protocol !== 'rtsp:' &&
    streamUri.protocol !== 'rtsps:'
  ) {
    throw new Error(
      'Kamera nie zwróciła strumienia RTSP.',
    );
  }

  streamUri.hostname = deviceEndpoint.hostname;
  streamUri.hash = '';
  return streamUri.toString();
}

async function sendSoap(
  endpoint,
  body,
  {
    fetchImpl,
    timeoutMs,
  },
) {
  const controller =
    new AbortController();

  let timedOut = false;

  const timeout =
    setTimeout(
      () => {
        timedOut = true;
        controller.abort();
      },
      timeoutMs,
    );

  try {
    const response =
      await fetchImpl(
        endpoint,
        {
          method: 'POST',
          headers: {
            'Content-Type':
              'application/soap+xml; charset=utf-8',
            'User-Agent':
              'SafeHood-Bridge/1.0',
          },
          body: body.trim(),
          redirect: 'error',
          signal:
            controller.signal,
        },
      );

    const responseBody =
      await response.text();

    if (!response.ok) {
      throw new Error(
        `HTTP ${response.status}`,
      );
    }

    return responseBody;
  } catch (error) {
    if (timedOut) {
      throw new Error(
        `Timeout ONVIF: ${endpoint.pathname}`,
      );
    }

    const message =
      error instanceof Error ?
        error.message :
        String(error);

    throw new Error(
      `${endpoint.pathname}: ${message}`,
    );
  } finally {
    clearTimeout(timeout);
  }
}

async function resolveOnvifStreamUri(
  camera,
  {
    fetchImpl = globalThis.fetch,
    timeoutMs = 10000,
  } = {},
) {
  if (typeof fetchImpl !== 'function') {
    throw new TypeError(
      'Brak implementacji fetch.',
    );
  }

  if (
    !Number.isFinite(timeoutMs) ||
    timeoutMs <= 0
  ) {
    throw new RangeError(
      'Nieprawidłowy timeout ONVIF.',
    );
  }

  const deviceServiceUrl =
    resolveDeviceServiceUrl(camera);

  // Bound the full negotiation, including fallback ports and profiles.
  const deadline = Date.now() + Math.min(30_000, timeoutMs * 5);
  const request = (endpoint, body) => sendSoap(endpoint, body, {
    fetchImpl, timeoutMs: Math.max(1, Math.min(timeoutMs, deadline - Date.now())),
  });

  const tried = new Set();
  let failure;
  async function resolveMedia(value, namespace) {
    const endpoint = parseHttpEndpoint(value, deviceServiceUrl, 'Media Service');
    const key = `${endpoint} ${namespace}`;
    if (tried.has(key)) return null;
    tried.add(key);

    const profilesXml = await request(
      endpoint, GET_PROFILES_SOAP.replace(MEDIA_V1, namespace),
    );
    const profiles = extractProfileTokens(profilesXml);
    if (!profiles.length) throw new Error('Brak profilu ONVIF Media.');

    for (const token of profiles) {
      for (const tcp of [true, false]) {
        if (Date.now() >= deadline) break;
        try {
          const xml = await request(endpoint, buildGetStreamUriSoap(token, namespace, tcp));
          const value = extractElementText(xml, 'Uri');
          if (!value) throw new Error('Brak Stream URI.');
          return parseStreamUri(value, deviceServiceUrl);
        } catch (error) {
          failure ??= error;
          // Credentials (if needed) are a separate setup step.
          if (/HTTP (401|403)\b/.test(error.message)) throw error;
        }
      }
    }
    return null;
  }

  try {
    const capabilities = await request(deviceServiceUrl, GET_CAPABILITIES_SOAP);
    const media = extractMediaServiceUrl(capabilities);
    if (media) {
      const uri = await resolveMedia(media, MEDIA_V1);
      if (uri) return uri;
    } else {
      failure ??= new Error('Brak Media Service XAddr.');
    }
  } catch (error) {
    failure ??= error;
  }

  if (!/HTTP (401|403)\b/.test(failure?.message ?? '') && Date.now() < deadline) {
    try {
      const services = await request(deviceServiceUrl, GET_SERVICES_SOAP);
      const list = services.matchAll(
        /<(?:[\w-]+:)?Service\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?Service>/gi,
      );
      let count = 0;
      for (const [, service] of list) {
        if (++count > 12 || Date.now() >= deadline) break;
        const namespace = extractElementText(service, 'Namespace');
        const address = extractElementText(service, 'XAddr');
        if (!address || ![MEDIA_V1, MEDIA_V2].includes(namespace)) continue;
        try {
          const uri = await resolveMedia(address, namespace);
          if (uri) return uri;
        } catch (error) {
          failure ??= error;
        }
      }
    } catch (error) {
      failure ??= error;
    }
  }
  throw failure ?? new Error('Kamera nie zwróciła adresu obrazu.');

}

module.exports = {
  resolveOnvifStreamUri,
};