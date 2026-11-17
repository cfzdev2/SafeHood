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
test('tries UDP and another profile if the advertised main stream fails', async () => {
  const calls = [];
  const fetchImpl = createFetch([
    {status: 200, body: '<Media><XAddr>http://0.0.0.0:8899/media</XAddr></Media>'},
    {status: 200, body: '<Profiles token="main"/><Profiles token="sub&amp;1"/>'},
    {status: 400, body: '<Fault/>'},
    {status: 400, body: '<Fault/>'},
    {status: 200, body: '<Uri>rtsp://0.0.0.0:554/sub?x=1&amp;y=2</Uri>'},
  ], calls);

  assert.equal(
    await resolveOnvifStreamUri(camera, {fetchImpl}),
    'rtsp://127.0.0.1:554/sub?x=1&y=2',
  );
  assert.equal(calls[1].endpoint, 'http://127.0.0.1:8899/media');
  assert.match(calls[2].body, /^<s:Envelope/);
  assert.match(calls[2].body, /<tt:Stream>RTP-Unicast<\/tt:Stream>/);
  assert.match(calls[3].body, /<tt:Protocol>UDP<\/tt:Protocol>/);
  assert.match(calls[4].body, /<trt:ProfileToken>sub&amp;1<\/trt:ProfileToken>/);
});

test('uses GetServices and Media2 when legacy Media is unavailable', async () => {
  const calls = [];
  const fetchImpl = createFetch([
    {status: 200, body: '<GetCapabilitiesResponse/>'},
    {status: 200, body:
      '<Service><Namespace>http://www.onvif.org/ver20/media/wsdl</Namespace>' +
      '<XAddr>/media2</XAddr></Service>'},
    {status: 200, body: '<Profiles token="m2"/>'},
    {status: 200, body: '<Uri>rtsp://127.0.0.1/live</Uri>'},
  ], calls);

  assert.equal(await resolveOnvifStreamUri(camera, {fetchImpl}), 'rtsp://127.0.0.1/live');
  assert.match(calls[1].body, /GetServices/);
  assert.equal(calls[2].endpoint, 'http://127.0.0.1:8080/media2');
  assert.match(calls[3].body, /<trt:Protocol>RTSP<\/trt:Protocol>/);
  assert.doesNotMatch(calls[3].body, /StreamSetup/);
});
