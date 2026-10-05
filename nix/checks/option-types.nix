# Interface names, addresses and CIDRs go into nft rules and scripts as they are: their
# types must turn away anything that would end the token there.
{ checkLib, minimal }:

let
  opts = minimal.options.services.proxy-suite;
  elemCheck = option: option.type.nestedTypes.elemType.check;
  accepts = check: builtins.all check;
  refuses = check: builtins.all (value: !(check value));
  injected = [
    ""
    "br0\" accept"
    "br0 }"
    "br0; flush ruleset"
    "$(reboot)"
    "eth0 eth1"
    "a\nb"
  ];
in
{
  assertions = [
    (
      let
        check = elemCheck opts.proxy.tproxy.lanInterfaces;
      in
      assert accepts check [
        "br0"
        "br-lan"
        "eth0.100"
        "wlp3s0"
        "a+b"
        "123456789012345"
      ];
      assert refuses check (
        injected
        ++ [
          "1234567890123456"
          "."
          "-x"
          "eth*"
        ]
      );
      assert refuses opts.proxy.tun.interface.type.check injected;
      assert refuses opts.perAppRouting.tun.interface.type.check injected;
      true
    )
    (
      let
        subnets = [
          opts.proxy.tproxy.localSubnets
          opts.perAppRouting.tun.localSubnets
          opts.perAppRouting.tproxy.localSubnets
          opts.perAppRouting.via.localSubnets
          opts.zapret.cidrExemption.cidrs
        ];
      in
      assert builtins.all (
        option:
        accepts (elemCheck option) [
          "192.168.0.0/16"
          "10.1.2.3"
          "fd00::/8"
          "::1"
          "::ffff:10.0.0.1/128"
        ]
        && refuses (elemCheck option) (
          injected
          ++ [
            "10.0.0.0/8 accept"
            "10.0.0.0/33"
            "256.0.0.0/8"
            "fd00::/129"
            "example.com"
          ]
        )
      ) subnets;
      true
    )
    (
      assert accepts opts.proxy.tun.address.type.check [ "172.19.0.1/30" ];
      assert refuses opts.proxy.tun.address.type.check (
        injected
        ++ [
          "172.19.0.1"
          "fd00::1/64"
          "172.19.0.1/30 accept"
        ]
      );
      assert refuses opts.perAppRouting.tun.address.type.check [ "172.20.0.1/30; drop" ];
      true
    )
    (
      assert accepts opts.proxy.listener.address.type.check [
        "127.0.0.1"
        "::"
        "localhost"
      ];
      assert refuses opts.proxy.listener.address.type.check injected;
      true
    )
    # A bad value stops the evaluation; it is not quietly left out.
    (
      assert
        !(checkLib.forceEval
          (minimal.extendModules {
            modules = [ { services.proxy-suite.proxy.tproxy.lanInterfaces = [ "br0\" accept" ]; } ];
          }).config.services.proxy-suite.proxy.tproxy.lanInterfaces
        ).success;
      true
    )
  ];
}
