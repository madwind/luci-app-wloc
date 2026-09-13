use std::collections::HashMap;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use rustls::crypto::ring::sign::any_supported_type;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;

pub struct CaBundle {
    params: CertificateParams,
    cert_der: Vec<u8>,
    key: KeyPair,
}

impl CaBundle {
    pub fn load_or_generate(
        dir: &Path,
    ) -> Result<(Self, bool), Box<dyn std::error::Error + Send + Sync>> {
        ensure_sane_clock()?;
        fs::create_dir_all(dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        }
        let key_path = dir.join("ca.key");
        let cert_path = dir.join("ca.der");
        if key_path.exists() && cert_path.exists() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600))?;
                fs::set_permissions(&cert_path, fs::Permissions::from_mode(0o600))?;
            }
            let key_der = fs::read(&key_path)?;
            let cert_der = fs::read(&cert_path)?;
            let key = KeyPair::from_pkcs8_der_and_sign_algo(
                &PrivatePkcs8KeyDer::from(key_der),
                &rcgen::PKCS_ECDSA_P256_SHA256,
            )?;
            let signing = any_supported_type(&PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
                key.serialize_der(),
            )))?;
            CertifiedKey::new(vec![CertificateDer::from(cert_der.clone())], signing)
                .keys_match()?;
            let pem_path = dir.join("ca.pem");
            if !pem_path.exists() {
                write_atomic(&pem_path, pem_certificate(&cert_der).as_bytes(), 0o644)?;
            }
            return Ok((
                Self {
                    params: ca_params()?,
                    cert_der,
                    key,
                },
                false,
            ));
        }
        let params = ca_params()?;
        let key = KeyPair::generate()?;
        let cert = params.self_signed(&key)?;
        let bundle = Self {
            params,
            cert_der: cert.der().to_vec(),
            key,
        };
        write_atomic(&key_path, &bundle.key.serialize_der(), 0o600)?;
        write_atomic(&cert_path, &bundle.cert_der, 0o600)?;
        write_atomic(
            &dir.join("ca.pem"),
            pem_certificate(&bundle.cert_der).as_bytes(),
            0o644,
        )?;
        Ok((bundle, true))
    }

    pub fn fingerprint(&self) -> String {
        let digest = ring::digest::digest(&ring::digest::SHA256, &self.cert_der);
        digest
            .as_ref()
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join(":")
    }

    pub fn cert_der(&self) -> &[u8] {
        &self.cert_der
    }

    fn leaf(
        &self,
        hostname: &str,
    ) -> Result<CertifiedKey, Box<dyn std::error::Error + Send + Sync>> {
        let mut params = CertificateParams::new(vec![hostname.to_owned()])?;
        params.is_ca = IsCa::NoCa;
        params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyEncipherment,
        ];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let now = time::OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::days(1);
        params.not_after = now + time::Duration::days(30);
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, hostname);
        params.distinguished_name = dn;
        let key = KeyPair::generate()?;
        let issuer = Issuer::from_params(&self.params, &self.key);
        let cert = params.signed_by(&key, &issuer)?;
        let signing = any_supported_type(&PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
            key.serialize_der(),
        )))?;
        Ok(CertifiedKey::new(
            vec![
                CertificateDer::from(cert.der().to_vec()),
                CertificateDer::from(self.cert_der.clone()),
            ],
            signing,
        ))
    }

    pub fn resolver(
        self: &Arc<Self>,
        domains: Vec<String>,
    ) -> Result<ApprovedResolver, Box<dyn std::error::Error + Send + Sync>> {
        let mut leaves = HashMap::new();
        for host in &domains {
            leaves.insert(
                host.to_owned(),
                CachedLeaf {
                    key: Arc::new(self.leaf(host)?),
                    generated: Instant::now(),
                },
            );
        }
        Ok(ApprovedResolver {
            ca: Arc::clone(self),
            domains,
            leaves: Mutex::new(leaves),
        })
    }
}

fn ensure_sane_clock() -> Result<(), &'static str> {
    const MINIMUM_UNIX_TIME: i64 = 1_704_067_200; // 2024-01-01 UTC
    if time::OffsetDateTime::now_utc().unix_timestamp() < MINIMUM_UNIX_TIME {
        return Err("system clock is not synchronized");
    }
    Ok(())
}

fn ca_params() -> Result<CertificateParams, rcgen::Error> {
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "OpenWrt WLOC Root CA");
    params.distinguished_name = dn;
    let now = time::OffsetDateTime::now_utc();
    params.not_before = now - time::Duration::days(1);
    params.not_after = now + time::Duration::days(3650);
    Ok(params)
}

fn write_atomic(
    path: &Path,
    data: &[u8],
    #[cfg_attr(not(unix), allow(unused_variables))] mode: u32,
) -> std::io::Result<()> {
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    let mut file = options.open(&temporary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
    }
    file.write_all(data)?;
    file.sync_all()?;
    fs::rename(temporary, path)
}

fn pem_certificate(der: &[u8]) -> String {
    let body = base64::engine::general_purpose::STANDARD.encode(der);
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).unwrap());
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");
    pem
}

fn stable_uuid(certificate: &[u8], label: &[u8]) -> String {
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    context.update(b"org.openwrt.wloc.mobileconfig\0");
    context.update(label);
    context.update(certificate);
    let digest = context.finish();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest.as_ref()[..16]);
    // RFC 9562 version 8 is reserved for application-defined UUIDs.
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])
}

pub fn write_mobileconfig(
    ca: &CaBundle,
    output: &Path,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let certificate = base64::engine::general_purpose::STANDARD.encode(ca.cert_der());
    let profile = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadContent</key><array><dict>
<key>PayloadCertificateFileName</key><string>wloc-ca.cer</string>
<key>PayloadContent</key><data>{certificate}</data>
<key>PayloadDisplayName</key><string>OpenWrt WLOC Root CA</string>
<key>PayloadIdentifier</key><string>org.openwrt.wloc.ca</string>
<key>PayloadType</key><string>com.apple.security.root</string>
<key>PayloadUUID</key><string>{}</string><key>PayloadVersion</key><integer>1</integer>
</dict></array>
<key>PayloadDescription</key><string>Root CA for the explicitly authorized OpenWrt WLOC test device</string>
<key>PayloadDisplayName</key><string>OpenWrt WLOC CA</string>
<key>PayloadIdentifier</key><string>org.openwrt.wloc.profile</string>
<key>PayloadOrganization</key><string>OpenWrt WLOC</string>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadUUID</key><string>{}</string><key>PayloadVersion</key><integer>1</integer>
</dict></plist>
"#,
        stable_uuid(ca.cert_der(), b"certificate"),
        stable_uuid(ca.cert_der(), b"profile")
    );
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    if fs::read(output).ok().as_deref() == Some(profile.as_bytes()) {
        return Ok(());
    }
    write_atomic(output, profile.as_bytes(), 0o644)?;
    Ok(())
}

pub struct ApprovedResolver {
    ca: Arc<CaBundle>,
    domains: Vec<String>,
    leaves: Mutex<HashMap<String, CachedLeaf>>,
}

struct CachedLeaf {
    key: Arc<CertifiedKey>,
    generated: Instant,
}
impl std::fmt::Debug for ApprovedResolver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedResolver").finish_non_exhaustive()
    }
}
impl ResolvesServerCert for ApprovedResolver {
    fn resolve(&self, hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let host = hello
            .server_name()?
            .trim_end_matches('.')
            .to_ascii_lowercase();
        if !crate::approved_host(&host, &self.domains) {
            return None;
        }
        let mut leaves = self
            .leaves
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(cached) = leaves.get(&host) {
            if cached.generated.elapsed() < Duration::from_secs(24 * 60 * 60) {
                return Some(Arc::clone(&cached.key));
            }
        }
        let key = Arc::new(self.ca.leaf(&host).ok()?);
        leaves.insert(
            host,
            CachedLeaf {
                key: Arc::clone(&key),
                generated: Instant::now(),
            },
        );
        Some(key)
    }
}

pub fn default_profile_path() -> PathBuf {
    PathBuf::from("/www/wloc-ca.mobileconfig")
}
