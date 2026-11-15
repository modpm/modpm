module modpm.cli.terminal;

import std.utf : decode;

import modpm.cli.prompter : PromptAborted;

version (Windows)
{
    import core.sys.windows.windows;

    private enum virtualTerminalInput = 0x0200;
    private enum virtualTerminalProcessing = 0x0004;
}
else version (Posix)
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.termios;
    import core.sys.posix.unistd : STDIN_FILENO, STDOUT_FILENO, isatty, read;
}

enum Key
{
    character,
    enter,
    tab,
    backspace,
    delete_,
    up,
    down,
    left,
    right,
    home,
    end,
    interrupt,
    clearLine,
    escape,
    unknown,
}

struct KeyPress
{
    Key key;
    dchar character;
}

final class Terminal
{
    private enum notInteractive =
        "interactive prompts need a terminal: pass every value as a flag and use --no-prompt";

    version (Posix)
    {
        private termios saved_;
    }
    else version (Windows)
    {
        private HANDLE input_;
        private HANDLE output_;
        private DWORD savedInputMode_;
        private DWORD savedOutputMode_;
        private UINT savedInputCodePage_;
        private UINT savedOutputCodePage_;
    }

    void enterRaw()
    {
        version (Posix)
        {
            if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)
                || tcgetattr(STDIN_FILENO, &saved_) != 0)
                throw new Exception(notInteractive);

            termios raw = saved_;
            raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
            raw.c_iflag &= ~(IXON | ICRNL);
            raw.c_cc[VMIN] = 1;
            raw.c_cc[VTIME] = 0;
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
        }
        else version (Windows)
        {
            input_ = GetStdHandle(STD_INPUT_HANDLE);
            output_ = GetStdHandle(STD_OUTPUT_HANDLE);
            if (!GetConsoleMode(input_, &savedInputMode_)
                || !GetConsoleMode(output_, &savedOutputMode_))
                throw new Exception(notInteractive);

            savedInputCodePage_ = GetConsoleCP();
            savedOutputCodePage_ = GetConsoleOutputCP();
            SetConsoleCP(65001);
            SetConsoleOutputCP(65001);
            SetConsoleMode(input_, (savedInputMode_
                    & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT))
                    | virtualTerminalInput);
            SetConsoleMode(output_, savedOutputMode_ | virtualTerminalProcessing);
        }
    }

    void leaveRaw()
    {
        version (Posix)
        {
            tcsetattr(STDIN_FILENO, TCSADRAIN, &saved_);
        }
        else version (Windows)
        {
            SetConsoleMode(input_, savedInputMode_);
            SetConsoleMode(output_, savedOutputMode_);
            SetConsoleCP(savedInputCodePage_);
            SetConsoleOutputCP(savedOutputCodePage_);
        }
    }

    KeyPress readKey()
    {
        immutable first = readByte();
        switch (first)
        {
        case '\r':
        case '\n':
            return KeyPress(Key.enter);
        case '\t':
            return KeyPress(Key.tab);
        case 0x7f:
        case 0x08:
            return KeyPress(Key.backspace);
        case 0x03:
            return KeyPress(Key.interrupt);
        case 0x15:
            return KeyPress(Key.clearLine);
        case 0x01:
            return KeyPress(Key.home);
        case 0x05:
            return KeyPress(Key.end);
        case 0x1b:
            return readEscape();
        default:
            break;
        }

        if (first < 0x20)
            return KeyPress(Key.unknown);
        return KeyPress(Key.character, readCharacter(first));
    }

    private KeyPress readEscape()
    {
        if (!byteReady(50))
            return KeyPress(Key.escape);

        immutable introducer = readByte();
        if (introducer != '[' && introducer != 'O')
            return KeyPress(Key.escape);

        int number = 0;
        bool inFirstParameter = true;
        ubyte next = readByte();
        while ((next >= '0' && next <= '9') || next == ';')
        {
            if (next == ';')
                inFirstParameter = false;
            else if (inFirstParameter)
                number = number * 10 + (next - '0');
            next = readByte();
        }

        switch (next)
        {
        case 'A':
            return KeyPress(Key.up);
        case 'B':
            return KeyPress(Key.down);
        case 'C':
            return KeyPress(Key.right);
        case 'D':
            return KeyPress(Key.left);
        case 'H':
            return KeyPress(Key.home);
        case 'F':
            return KeyPress(Key.end);
        case '~':
            switch (number)
            {
            case 1:
            case 7:
                return KeyPress(Key.home);
            case 3:
                return KeyPress(Key.delete_);
            case 4:
            case 8:
                return KeyPress(Key.end);
            default:
                return KeyPress(Key.unknown);
            }
        default:
            return KeyPress(Key.unknown);
        }
    }

    private dchar readCharacter(ubyte first)
    {
        size_t length;
        if (first < 0x80)
            length = 1;
        else if ((first & 0xE0) == 0xC0)
            length = 2;
        else if ((first & 0xF0) == 0xE0)
            length = 3;
        else if ((first & 0xF8) == 0xF0)
            length = 4;
        else
            return '\uFFFD';

        char[] bytes = [cast(char) first];
        foreach (_; 1 .. length)
            bytes ~= cast(char) readByte();

        size_t index = 0;
        try
            return decode(bytes, index);
        catch (Exception)
            return '\uFFFD';
    }

    private ubyte readByte()
    {
        version (Posix)
        {
            ubyte value;
            while (true)
            {
                immutable count = read(STDIN_FILENO, &value, 1);
                if (count == 1)
                    return value;
                if (count == 0)
                    throw new PromptAborted();
                if (errno != EINTR)
                    throw new Exception("cannot read from the terminal");
            }
        }
        else version (Windows)
        {
            ubyte value;
            DWORD count;
            if (!ReadFile(input_, &value, 1, &count, null) || count == 0)
                throw new PromptAborted();
            return value;
        }
    }

    private bool byteReady(int milliseconds)
    {
        version (Posix)
        {
            pollfd descriptor;
            descriptor.fd = STDIN_FILENO;
            descriptor.events = POLLIN;
            return poll(&descriptor, 1, milliseconds) > 0;
        }
        else version (Windows)
        {
            return WaitForSingleObject(input_, milliseconds) == WAIT_OBJECT_0;
        }
    }
}
