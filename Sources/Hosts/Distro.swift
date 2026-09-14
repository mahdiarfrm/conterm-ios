import SwiftUI

/// What a host runs, as the one word a mark can stand for. The detection is
/// the Mac app's, unchanged: most specific first, because Raspberry Pi OS
/// and Kali both say "Debian" somewhere and Proxmox is a Debian worth
/// naming itself.
///
/// The marks are Simple Icons, CC0, rasterised into the asset catalogue as
/// template images, so a mark takes whatever colour the surface gives it and
/// a fleet reads as one surface rather than twenty competing logos.
enum Distro: String, Codable, CaseIterable, Sendable {
    case ubuntu, debian, fedora, rhel, centos, rocky, alma, arch, alpine
    case suse, nixos, gentoo, manjaro, raspbian, amazon, kali, mint
    case proxmox, openwrt, freebsd, macos

    static func detect(_ description: String?) -> Distro? {
        guard let s = description?.lowercased(), !s.isEmpty else { return nil }
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }
        switch true {
        case has("raspbian", "raspberry"):    return .raspbian
        case has("proxmox"):                  return .proxmox
        case has("kali"):                     return .kali
        case has("linux mint", "linuxmint"):  return .mint
        case has("manjaro"):                  return .manjaro
        case has("ubuntu"):                   return .ubuntu
        case has("debian", "devuan"):         return .debian
        case has("fedora"):                   return .fedora
        case has("almalinux"):                return .alma
        case has("rocky"):                    return .rocky
        case has("centos"):                   return .centos
        case has("amazon linux"):             return .amazon
        case has("red hat", "redhat", "rhel", "oracle linux"): return .rhel
        case has("arch"):                     return .arch
        case has("alpine"):                   return .alpine
        case has("suse", "sles"):             return .suse
        case has("nixos"):                    return .nixos
        case has("gentoo"):                   return .gentoo
        case has("openwrt"):                  return .openwrt
        case has("freebsd"):                  return .freebsd
        case has("macos", "mac os", "darwin"): return .macos
        default:                              return nil
        }
    }

    var label: String {
        switch self {
        case .ubuntu:   return "Ubuntu"
        case .debian:   return "Debian"
        case .fedora:   return "Fedora"
        case .rhel:     return "RHEL"
        case .centos:   return "CentOS"
        case .rocky:    return "Rocky"
        case .alma:     return "AlmaLinux"
        case .arch:     return "Arch"
        case .alpine:   return "Alpine"
        case .suse:     return "SUSE"
        case .nixos:    return "NixOS"
        case .gentoo:   return "Gentoo"
        case .manjaro:  return "Manjaro"
        case .raspbian: return "Raspberry Pi OS"
        case .amazon:   return "Amazon Linux"
        case .kali:     return "Kali"
        case .mint:     return "Mint"
        case .proxmox:  return "Proxmox"
        case .openwrt:  return "OpenWrt"
        case .freebsd:  return "FreeBSD"
        case .macos:    return "macOS"
        }
    }

    /// The asset the mark is drawn from.
    var imageName: String {
        switch self {
        case .ubuntu:   return "distro-ubuntu"
        case .debian:   return "distro-debian"
        case .fedora:   return "distro-fedora"
        case .rhel:     return "distro-redhat"
        case .centos:   return "distro-centos"
        case .rocky:    return "distro-rockylinux"
        case .alma:     return "distro-almalinux"
        case .arch:     return "distro-archlinux"
        case .alpine:   return "distro-alpinelinux"
        case .suse:     return "distro-opensuse"
        case .nixos:    return "distro-nixos"
        case .gentoo:   return "distro-gentoo"
        case .manjaro:  return "distro-manjaro"
        case .raspbian: return "distro-raspberrypi"
        case .amazon:   return "distro-linux"
        case .kali:     return "distro-kalilinux"
        case .mint:     return "distro-linuxmint"
        case .proxmox:  return "distro-proxmox"
        case .openwrt:  return "distro-openwrt"
        case .freebsd:  return "distro-freebsd"
        case .macos:    return "distro-apple"
        }
    }
}

/// The mark, monochrome, in whatever colour it is given. A host whose
/// distribution is unknown gets the plain penguin; a host that is only a
/// name gets a prompt.
struct DistroMark: View {
    var distro: Distro?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let distro {
                Image(distro.imageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.bold)
            }
        }
        .frame(width: size, height: size)
    }
}
