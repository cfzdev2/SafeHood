'use strict';

const RECONNECT_DELAYS_MS = [
  2000,
  4000,
  8000,
  16000,
  30000,
];

const GET_CAPABILITIES_SOAP =
  `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <GetCapabilities
   xmlns="http://www.onvif.org/ver10/device/wsdl">
   <Category>All</Category>
  </GetCapabilities>
 </s:Body>
</s:Envelope>`;

const CREATE_PULL_POINT_SOAP =
  `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <CreatePullPointSubscription
   xmlns="http://www.onvif.org/ver10/events/wsdl">
   <InitialTerminationTime>
    PT1H
   </InitialTerminationTime>
  </CreatePullPointSubscription>
 </s:Body>
</s:Envelope>`;

const PULL_MESSAGES_SOAP =
  `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <PullMessages
   xmlns="http://www.onvif.org/ver10/events/wsdl">
   <Timeout>PT5S</Timeout>
   <MessageLimit>10</MessageLimit>
  </PullMessages>
 </s:Body>
</s:Envelope>`;

function decodeXmlText(value) {
  return value
    .replace(/&quot;/gi, '"')
    .replace(/&apos;/gi, '\'')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) =>
      String.fromCodePoint(
        Number.parseInt(hex, 16),
      ),
    )
    .replace(/&#([0-9]+);/g, (_, decimal) =>
      String.fromCodePoint(
        Number.parseInt(decimal, 10),
      ),
    )
    .replace(/&amp;/gi, '&')
    .trim();
}

function extractEventsServiceUrl(xml) {
  const openingTagMatch = xml.match(
    /<(?:\w+:)?Events\b([^>]*)>/i,
  );

  const attributes =
    openingTagMatch?.[1] ?? '';

  const attributeMatch = attributes.match(
    /\bXAddr\s*=\s*["']([^"']+)["']/i,
  );

  if (attributeMatch?.[1]) {
    return decodeXmlText(
      attributeMatch[1],
    );
  }

  const eventsBlockMatch = xml.match(
    /<(?:\w+:)?Events\b[^>]*>([\s\S]*?)<\/(?:\w+:)?Events>/i,
  );

  const eventsBlock =
    eventsBlockMatch?.[1] ?? xml;

  const elementMatch = eventsBlock.match(
    /<(?:\w+:)?XAddr\b[^>]*>\s*([^<]+?)\s*<\/(?:\w+:)?XAddr>/i,
  );

  if (!elementMatch?.[1]) {
    return null;
  }

  return decodeXmlText(
    elementMatch[1],
  );
}

function extractPullPointUrl(xml) {
  const match = xml.match(
    /<(?:\w+:)?Address\b[^>]*>\s*([^<]+?)\s*<\/(?:\w+:)?Address>/i,
  );

  if (!match?.[1]) {
    return null;
  }

  return decodeXmlText(
    match[1],
  );
}

function parseOccurredAt(xml) {
  const match = xml.match(
    /\bUtcTime\s*=\s*["']([^"']+)["']/i,
  );

  const value =
    match?.[1]?.trim();

  if (!value) {
    return new Date().toISOString();
  }

  const date =
    new Date(value);

  if (Number.isNaN(date.getTime())) {
    return new Date().toISOString();
  }

  return date.toISOString();
}

function confidenceFor(type) {
  switch (type) {
    case 'person':
      return 0.94;

    case 'vehicle':
      return 0.88;

    case 'motion':
      return 0.62;

    default:
      return null;
  }
}

function parseDetection(xml) {
  const lower =
    xml.toLowerCase();

  if (!lower.includes(
    'notificationmessage',
  )) {
    return null;
  }

  let type = null;

  if (
    lower.includes('person') ||
    lower.includes('human')
  ) {
    type = 'person';
  } else if (
    lower.includes('vehicle') ||
    lower.includes('car')
  ) {
    type = 'vehicle';
  } else if (
    lower.includes('motion')
  ) {
    type = 'motion';
  }

  if (!type) {
    return null;
  }

  return {
    type,
    occurredAt:
      parseOccurredAt(xml),
    source:
      'onvif',
    confidence:
      confidenceFor(type),
  };
}

function normalizePorts(value) {
  if (value instanceof Set) {
    return [...value]
      .map(Number)
      .filter(Number.isInteger)
      .sort((a, b) => a - b);
  }

  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map(Number)
    .filter(Number.isInteger)
    .sort((a, b) => a - b);
}

function connectionFingerprint(camera) {
  return JSON.stringify({
    connectionType:
      camera.connectionType ?? null,
    ipAddress:
      camera.ipAddress ?? null,
    onvifServiceUrl:
      camera.onvifServiceUrl ?? null,
    openPorts:
      normalizePorts(
        camera.openPorts,
      ),
  });
}

function resolveDeviceServiceUrl(camera) {
  const configuredUrl =
    typeof camera.onvifServiceUrl ===
    'string' ?
      camera.onvifServiceUrl.trim() :
      '';

  if (configuredUrl) {
    const url =
      new URL(configuredUrl);

    if (
      url.protocol !== 'http:' &&
      url.protocol !== 'https:'
    ) {
      throw new Error(
        `Nieobsługiwany protokół ONVIF: ${url.protocol}`,
      );
    }

    return url;
  }

  const ipAddress =
    typeof camera.ipAddress ===
    'string' ?
      camera.ipAddress.trim() :
      '';

  if (!ipAddress) {
    throw new Error(
      'Brak onvifServiceUrl oraz ipAddress.',
    );
  }

  const ports =
    normalizePorts(
      camera.openPorts,
    );

  const preferredPorts = [
    8899,
    80,
    8000,
    8080,
    443,
    8443,
  ];

  const port =
    preferredPorts.find(
      (candidate) =>
        ports.includes(candidate),
    ) ??
    ports[0] ??
    80;

  const protocol =
    port === 443 ||
    port === 8443 ?
      'https' :
      'http';

  return new URL(
    `${protocol}://${ipAddress}:${port}/onvif/device_service`,
  );
}

class OnvifCameraSession {
    constructor({
    camera,
    onDetection,
    onStatusChanged,
  }) {
    if (
      !camera ||
      typeof camera.id !== 'string'
    ) {
      throw new Error(
        'Nieprawidłowa kamera.',
      );
    }

    if (
      typeof onDetection !==
      'function'
    ) {
      throw new Error(
        'Brak funkcji onDetection.',
      );
    }

        if (
      typeof onStatusChanged !==
      'function'
    ) {
      throw new Error(
        'Brak funkcji onStatusChanged.',
      );
    }

        this.camera = camera;
    this.onDetection = onDetection;
    this.onStatusChanged =
      onStatusChanged;

    this.reportedStatus = null;
    this.statusQueue =
      Promise.resolve();

    this.running = false;
    this.loopPromise = null;

    this.requestController = null;

    this.waitTimer = null;
    this.waitResolve = null;

        this.reconnectAttempt = 0;
  }

  reportStatus(status) {
    if (
      this.reportedStatus ===
      status
    ) {
      return this.statusQueue;
    }

    this.reportedStatus = status;

    this.statusQueue =
      this.statusQueue
        .then(
          () =>
            this.onStatusChanged(
              this.camera,
              status,
            ),
        )
        .catch(
          (error) => {
            console.error(
              `[BRIDGE CAMERA]` +
              `[${this.camera.id}] ` +
              `status write: ` +
              `${error.message}`,
            );
          },
        );

    return this.statusQueue;
  }

  start() {
    if (this.running) {
      return;
    }

        this.running = true;

    void this.reportStatus(
      'connecting',
    );

    console.log(
      `[BRIDGE ONVIF][${this.camera.id}] start`,
    );

    this.loopPromise =
      this.run();
  }

  async stop() {
    if (!this.running) {
      return;
    }

    this.running = false;

    this.requestController
      ?.abort();

    this.cancelWait();

    try {
      await this.loopPromise;
    } catch (_) {
      // Błąd został już obsłużony
      // wewnątrz pętli sesji.
    }

        this.loopPromise = null;
    this.requestController = null;

    await this.reportStatus(
      'offline',
    );

    console.log(
      `[BRIDGE ONVIF][${this.camera.id}] zatrzymano`,
    );
  }

  async run() {
    while (this.running) {
      try {
        await this.connectAndPoll();
      } catch (error) {
                if (!this.running) {
          break;
        }

        void this.reportStatus(
          'reconnecting',
        );

        console.error(
          `[BRIDGE ONVIF][${this.camera.id}] ${error.message}`,
        );
      }

      if (!this.running) {
        break;
      }

      const delayIndex =
        Math.min(
          this.reconnectAttempt,
          RECONNECT_DELAYS_MS.length - 1,
        );

      const delay =
        RECONNECT_DELAYS_MS[
          delayIndex
        ];

      this.reconnectAttempt += 1;

      console.log(
        `[BRIDGE ONVIF][${this.camera.id}] ` +
        `reconnect za ${delay / 1000} s`,
      );

      await this.wait(delay);
    }
  }

  async connectAndPoll() {
    const deviceServiceUrl =
      resolveDeviceServiceUrl(
        this.camera,
      );

    console.log(
      `[BRIDGE ONVIF][${this.camera.id}] ` +
      `łączę ${deviceServiceUrl}`,
    );

    const capabilitiesXml =
      await this.sendSoap(
        deviceServiceUrl,
        GET_CAPABILITIES_SOAP,
        10000,
      );

    if (
      !this.running ||
      capabilitiesXml == null
    ) {
      return;
    }

    const eventsValue =
      extractEventsServiceUrl(
        capabilitiesXml,
      );

    if (!eventsValue) {
      throw new Error(
        'Brak Events Service XAddr.',
      );
    }

    const eventsServiceUrl =
      new URL(eventsValue);

    const subscriptionXml =
      await this.sendSoap(
        eventsServiceUrl,
        CREATE_PULL_POINT_SOAP,
        10000,
      );

    if (
      !this.running ||
      subscriptionXml == null
    ) {
      return;
    }

    const pullPointValue =
      extractPullPointUrl(
        subscriptionXml,
      );

    if (!pullPointValue) {
      throw new Error(
        'Brak adresu PullPoint.',
      );
    }

    const pullPointUrl =
      new URL(pullPointValue);

    this.reconnectAttempt = 0;

        console.log(
      `[BRIDGE ONVIF][${this.camera.id}] ` +
      `PullPoint = ${pullPointUrl}`,
    );

    await this.reportStatus(
      'online',
    );

    while (this.running) {
      const responseXml =
        await this.sendSoap(
          pullPointUrl,
          PULL_MESSAGES_SOAP,
          15000,
        );

      if (
        !this.running ||
        responseXml == null
      ) {
        return;
      }

      const detection =
        parseDetection(
          responseXml,
        );

      if (!detection) {
        continue;
      }

      console.log(
        `[BRIDGE ONVIF][${this.camera.id}] ` +
        `event ${detection.type}`,
      );

      try {
        await this.onDetection(
          this.camera,
          detection,
        );
      } catch (error) {
        console.error(
          `[BRIDGE INGEST][${this.camera.id}] ` +
          `${error.message}`,
        );
      }
    }
  }

  async sendSoap(
    endpoint,
    body,
    timeoutMs,
  ) {
    if (!this.running) {
      return null;
    }

    const controller =
      new AbortController();

    this.requestController =
      controller;

    let timedOut = false;

    const timeout = setTimeout(
      () => {
        timedOut = true;
        controller.abort();
      },
      timeoutMs,
    );

    try {
      const response =
        await fetch(
          endpoint,
          {
            method:
              'POST',

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
          `HTTP ${response.status} dla ${endpoint.pathname}`,
        );
      }

      return responseBody;
    } catch (error) {
      if (!this.running) {
        return null;
      }

      if (timedOut) {
        throw new Error(
          `timeout ${endpoint.pathname}`,
        );
      }

      throw new Error(
        `${endpoint.pathname}: ${error.message}`,
      );
    } finally {
      clearTimeout(timeout);

      if (
        this.requestController ===
        controller
      ) {
        this.requestController =
          null;
      }
    }
  }

  wait(milliseconds) {
    if (!this.running) {
      return Promise.resolve();
    }

    return new Promise(
      (resolve) => {
        this.waitResolve =
          resolve;

        this.waitTimer =
          setTimeout(
            () => {
              this.waitTimer =
                null;

              this.waitResolve =
                null;

              resolve();
            },
            milliseconds,
          );
      },
    );
  }

  cancelWait() {
    if (this.waitTimer) {
      clearTimeout(
        this.waitTimer,
      );

      this.waitTimer = null;
    }

    if (this.waitResolve) {
      const resolve =
        this.waitResolve;

      this.waitResolve = null;

      resolve();
    }
  }
}

module.exports = {
  OnvifCameraSession,
  connectionFingerprint,
};