'use strict';

const localHttpHosts =
  new Set([
    '127.0.0.1',
    'localhost',
    '[::1]',
    '::1',
  ]);

/**
 * Odrzuca nieszyfrowane zewnętrzne adresy backendu.
 *
 * @param {string} value Adres endpointu lub bazowy adres Functions.
 * @param {string} label Nazwa adresu w komunikacie błędu.
 * @return {string} Zweryfikowany adres.
 */
function requireSecureEndpoint(
  value,
  label,
) {
  let endpoint;

  try {
    endpoint =
      new URL(value);
  } catch (_) {
    throw new Error(
      `${label} ma nieprawidłowy adres.`,
    );
  }

  if (
    endpoint.username ||
    endpoint.password
  ) {
    throw new Error(
      `${label} nie może zawierać danych logowania.`,
    );
  }

  const hostname =
    endpoint.hostname.toLowerCase();

  const isSecure =
    endpoint.protocol === 'https:';

  const isLocalEmulator =
    endpoint.protocol === 'http:' &&
    localHttpHosts.has(hostname);

  if (!isSecure && !isLocalEmulator) {
    throw new Error(
      `${label} musi używać HTTPS. ` +
      'HTTP jest dozwolone tylko dla lokalnego emulatora.',
    );
  }

  return value;
}

module.exports = {
  requireSecureEndpoint,
};