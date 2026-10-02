rule RIT_WaterShell_UDP_Command_Backdoor
{
    meta:
        source = "https://github.com/RITRedteam/watershell"
        source_revision = "56c821053d39f4ad1f6cd11d7db610de98962c54"
        confidence = "review lead: source strings can be changed"
    strings:
        $status = "status:" ascii
        $run = "run:" ascii
        $doing = "Doing the thing: %s" ascii
        $listen = "Listening on %s" ascii
    condition:
        uint32(0) == 0x464c457f and filesize < 20MB and all of them
}

rule RIT_Goofkit_Kernel_Rootkit
{
    meta:
        source = "https://github.com/RITRedteam/goofkit"
        source_revision = "92cdf52d263bf9e3037be536a981e66af554ce63"
        confidence = "review lead: source strings can be changed"
    strings:
        $load = "[goof] module loaded" ascii
        $remove = "[goof] module removed" ascii
        $magic = "E1e37" ascii
        $hook = "Hooked getdents" ascii
    condition:
        uint32(0) == 0x464c457f and filesize < 20MB and all of them
}

rule RIT_Father_Default_LD_PRELOAD_Rootkit
{
    meta:
        source = "https://github.com/RITRedteam/Father/tree/51e6911b8fd922c4236666203842b4afece73f14/src"
        source_revision = "51e6911b8fd922c4236666203842b4afece73f14"
        confidence = "high-specificity default-source string conjunction; review lead only"
        limitations = "Modified configuration, obfuscation or build changes can evade; not proof of execution"
    strings:
        $default_marker = "lobster" ascii
        $default_library = "/lib/selinux.so.3" ascii
        $preload = "ld.so.preload" ascii
        $message = "Enjoy the shell!" ascii
        $crypto_hook = "gcry_pk_verify" ascii
    condition:
        uint32(0) == 0x464c457f and filesize < 20MB and all of them
}