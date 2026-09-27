'use strict';

const assert =
  require('node:assert/strict');

const {
  test,
} = require('node:test');

const {
  resolveOnvifStreamUri,
} = require(
  '../onvif_stream_resolver',
);

const camera = {
  id: 'camera-1',
  onvifServiceUrl:
    'http://127.0.0.1:8080/onvif/device_service',
};

function createFetch(
  responses,
  calls,
) {
  return async (
    endpoint,
    options,
  ) => {
    calls.push({
      endpoint:
        endpoint.toString(),
      body:
        options.body,
    });

    const response =
      responses.shift();

    if (!response) {
      throw new Error(
        'Brak przygotowanej odpowiedzi.',
      );
    }

    return {
      ok:
        response.status >= 200 &&
        response.status < 300,
      status:
        response.status,
      text:
        async () => response.body,
    };
  };
}

test(
  'pobiera adres RTSP przez ONVIF',
  async () => {
    const calls = [];

    const fetchImpl =
      createFetch(
        [
          {
            status: 200,
            body: `
<s:Envelope>
 <s:Body>
  <tds:GetCapabilitiesResponse>
   <tds:Capabilities>
    <tt:Media>
     <tt:XAddr>
      /onvif/media_service
     </tt:XAddr>
    </tt:Media>
   </tds:Capabilities>
  </tds:GetCapabilitiesResponse>
 </s:Body>
</s:Envelope>`,
          },
          {
            status: 200,
            body: `
<s:Envelope>
 <s:Body>
  <trt:GetProfilesResponse>
   <trt:Profiles token="profile&amp;1"/>
  </trt:GetProfilesResponse>
 </s:Body>
</s:Envelope>`,
          },
          {
            status: 200,
            body: `
<s:Envelope>
 <s:Body>
  <trt:GetStreamUriResponse>
   <trt:MediaUri>
    <tt:Uri>
     rtsp://127.0.0.1:8554/live?channel=1&amp;subtype=0
    </tt:Uri>
   </trt:MediaUri>
  </trt:GetStreamUriResponse>
 </s:Body>
</s:Envelope>`,
          },
        ],
        calls,
      );

    const streamUri =
      await resolveOnvifStreamUri(
        camera,
        {
          fetchImpl,
        },
      );

    assert.equal(
      streamUri,
      'rtsp://127.0.0.1:8554/live?channel=1&subtype=0',
    );

    assert.equal(
      calls.length,
      3,
    );

    assert.match(
      calls[0].body,
      /GetCapabilities/,
    );

    assert.match(
      calls[1].body,
      /GetProfiles/,
    );

    assert.match(
      calls[2].body,
      /profile&amp;1/,
    );
  },
);

test(
  'odrzuca brak Media Service',
  async () => {
    const fetchImpl =
      createFetch(
        [
          {
            status: 200,
            body: `
<s:Envelope>
 <s:Body>
  <tds:GetCapabilitiesResponse/>
 </s:Body>
</s:Envelope>`,
          },
        ],
        [],
      );

    await assert.rejects(
      resolveOnvifStreamUri(
        camera,
        {
          fetchImpl,
        },
      ),
      /Brak Media Service XAddr/,
    );
  },
);

test(
  'odrzuca strumień bez RTSP',
  async () => {
    const fetchImpl =
      createFetch(
        [
          {
            status: 200,
            body: `
<tt:Media>
 <tt:XAddr>
  http://127.0.0.1:8080/onvif/media_service
 </tt:XAddr>
</tt:Media>`,
          },
          {
            status: 200,
            body: `
<trt:Profiles token="profile_1"/>`,
          },
          {
            status: 200,
            body: `
<tt:Uri>
 http://127.0.0.1/video
</tt:Uri>`,
          },
        ],
        [],
      );

    await assert.rejects(
      resolveOnvifStreamUri(
        camera,
        {
          fetchImpl,
        },
      ),
      /nie zwróciła strumienia RTSP/,
    );
  },
);

test(
  'zgłasza błąd odpowiedzi ONVIF',
  async () => {
    const fetchImpl =
      createFetch(
        [
          {
            status: 500,
            body: 'Błąd kamery',
          },
        ],
        [],
      );

    await assert.rejects(
      resolveOnvifStreamUri(
        camera,
        {
          fetchImpl,
        },
      ),
      /HTTP 500/,
    );
  },
);