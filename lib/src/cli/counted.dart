/// [count] of [noun], for a command's output: "1 golden", "2 goldens".
String counted(int count, String noun) =>
    '$count $noun${count == 1 ? '' : 's'}';
