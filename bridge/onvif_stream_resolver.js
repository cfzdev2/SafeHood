'use strict';

const {
  resolveDeviceServiceUrl,
} = require('./onvif_camera_session');

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

function extractFirstProfileToken(xml) {
  const match =
    /<(?:[\w-]+:)?Profiles\b[^>]*\btoken\s*=\s*["']([^"']+)["']/i
      .exec(xml);

  if (!match) {
    return null;
  }

  const value =
    decodeXmlText(
      match[1].trim(),
    );

  return value || null;
}

function buildGetStreamUriSoap(
  profileToken,
) {
  const token =
    escapeXmlText(profileToken);

  return `
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
 xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body>
  <trt:GetStreamUri>
   <trt:StreamSetup>
    <tt:Stream>RTP-Unicast</tt:Stream>
    <tt:Transport>
     <tt:Protocol>RTSP</tt:Protocol>
    </tt:Transport>
   </trt:StreamSetup>
   <trt:ProfileToken>${token}</trt:ProfileToken>
  </trt:GetStreamUri>
 </s:Body>
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

  return endpoint;
}

function parseStreamUri(value) {
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
          body,
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

  const capabilitiesXml =
    await sendSoap(
      deviceServiceUrl,
      GET_CAPABILITIES_SOAP,
      {
        fetchImpl,
        timeoutMs,
      },
    );

  const mediaValue =
    extractMediaServiceUrl(
      capabilitiesXml,
    );

  if (!mediaValue) {
    throw new Error(
      'Brak Media Service XAddr.',
    );
  }

  const mediaServiceUrl =
    parseHttpEndpoint(
      mediaValue,
      deviceServiceUrl,
      'Media Service',
    );

  const profilesXml =
    await sendSoap(
      mediaServiceUrl,
      GET_PROFILES_SOAP,
      {
        fetchImpl,
        timeoutMs,
      },
    );

  const profileToken =
    extractFirstProfileToken(
      profilesXml,
    );

  if (!profileToken) {
    throw new Error(
      'Brak profilu ONVIF Media.',
    );
  }

  const streamXml =
    await sendSoap(
      mediaServiceUrl,
      buildGetStreamUriSoap(
        profileToken,
      ),
      {
        fetchImpl,
        timeoutMs,
      },
    );

  const streamValue =
    extractElementText(
      streamXml,
      'Uri',
    );

  if (!streamValue) {
    throw new Error(
      'Brak Stream URI.',
    );
  }

  return parseStreamUri(
    streamValue,
  );
}

module.exports = {
  resolveOnvifStreamUri,
};