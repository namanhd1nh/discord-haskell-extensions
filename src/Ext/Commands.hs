{-# LANGUAGE GADTs #-}

module Ext.Commands
  ( Context
  , Commands
  , cmds
  , cmd0
  , cmdA
  , cmd1, cmd2, cmd3, cmd4
  , alias
  , refer
  , restCreateMessage
  , processCommands
  ) where

import Control.Monad.State
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Char (isSpace)

import Discord
import Discord.Types
import Discord.Requests as DR

import Ext.Mentionables

-- | Context data type. Wraps the handle (for IO) and the Message 
-- that invoked the command
type Context = (DiscordHandle, Message)

-- | Shorthand synonym for the type of a user-defined IO function for a
-- zero-argument or subdivided command
type CmdFunc0 = Context -> IO ()

-- | Shorthand synonym for the type of a user-defined IO function for a 
-- command that takes a greedy argument.
type CmdFuncA = Context -> T.Text -> IO ()

-- | A wrapper type for user-def IO functions for commands with multiple args
data MultiArgCommandFunction where
  CmdFunc1 :: (Mentionable a) =>
    (Context -> a -> IO ()) -> MultiArgCommandFunction
  CmdFunc2 :: (Mentionable a, Mentionable b) => 
    (Context -> a -> b -> IO ()) -> MultiArgCommandFunction
  CmdFunc3 :: (Mentionable a, Mentionable b, Mentionable c) => 
    (Context -> a -> b -> c -> IO ()) -> MultiArgCommandFunction
  CmdFunc4 :: (Mentionable a, Mentionable b, Mentionable c, Mentionable d) =>
    (Context -> a -> b -> c -> d -> IO ()) -> MultiArgCommandFunction

-- | Command data type. Holds information on how the user-defined IO function
-- should be executed and whether there are subcommands.
data Command = 
    Cmds CmdFunc0 CommandTree
  | Cmd0 CmdFunc0
  | CmdA CmdFuncA
  | CmdN MultiArgCommandFunction

-- | PrettyCommand wrapper for a Command, for use in e.g. help messages.
data PrettyCommand =
  PrettyCmd { name :: T.Text
            , command :: Command
            , synopsis :: T.Text
            , description :: T.Text}

-- | Internal representation of the command hierarchy.
-- TODO: change this to something faster maybe?
type CommandTree = [PrettyCommand]

-- | A map to map aliases to the "main" names of commands.
-- The "main" name is the one that is specified in the cmd definition in the 
-- monadic block.
type AliasMap = M.Map T.Text T.Text

-- | A monad for building up the state of the command hierarchy and aliases. 
-- This is to make use of do notation to make the user's life easier 
-- when defining a custom command hierarchy.
type Commands = State (CommandTree, AliasMap) PrettyCommand

-- | Update the state with a new command and add alias accordingly
addAndReturnCmd :: PrettyCommand -> Commands
addAndReturnCmd c = let n = name c in
  modify (\(cs,as) -> (c:cs,M.insert n n as)) *> pure c

-- | A command with subcommands
cmds :: T.Text -> CmdFunc0 -> T.Text -> T.Text -> Commands -> Commands
cmds name func syn desc subsState = let (subs, aliases) = execState subsState ([],M.empty) in do
  returnCmd <- addAndReturnCmd (PrettyCmd name (Cmds func subs) syn desc)
  modify (\(cs,as) -> (cs,M.union aliases as))
  pure returnCmd

-- | Helper to factor out the addAndReturnCmd
registerInternalCmd :: T.Text -> Command -> T.Text -> T.Text -> Commands
registerInternalCmd name internalCmd syn desc = 
  addAndReturnCmd $ PrettyCmd name internalCmd syn desc

-- | A command with no arguments
cmd0 :: T.Text -> CmdFunc0 -> T.Text -> T.Text -> Commands
cmd0 name func syn desc = registerInternalCmd name (Cmd0 func) syn desc

-- | A command with a greedy argument. Everything after the command's name is the argument.
cmdA :: T.Text -> CmdFuncA -> T.Text -> T.Text -> Commands
cmdA name func syn desc = registerInternalCmd name (CmdA func) syn desc

-- | Multi-arg commands. (Type sigs similar to above)
cmd1 name func syn desc = registerInternalCmd name (CmdN (CmdFunc1 func)) syn desc
cmd2 name func syn desc = registerInternalCmd name (CmdN (CmdFunc2 func)) syn desc
cmd3 name func syn desc = registerInternalCmd name (CmdN (CmdFunc3 func)) syn desc
cmd4 name func syn desc = registerInternalCmd name (CmdN (CmdFunc4 func)) syn desc

-- | Reuse a command (used to make a command also a subcommand of 
-- another command on the same level)
refer :: PrettyCommand -> Commands
refer = addAndReturnCmd

-- | Set an alias for a command
alias :: T.Text -> PrettyCommand -> Commands
alias a c = modify (\(cs,as) -> (cs,M.insert a (name c) as)) *> pure c

-- Convenience functions to wrap common requests
restCreateMessage :: Context -> T.Text -> IO ()
restCreateMessage (dis, msg) t = 
  (restCall dis $ DR.CreateMessage (messageChannel msg) t) *> pure ()

-- | =Evaluating commands= ---------------------

-- | Parse and try to evaluate the command into an IO action
parseAndEvalCommand :: Context -> CommandTree -> AliasMap -> T.Text -> Either String (IO ())
parseAndEvalCommand ctx [] _ remains = 
  Left $ "No command was defined"
parseAndEvalCommand ctx (cmd:cmds) aliases remains =
  case M.lookup prefixText aliases of
    Nothing -> Left $ "Command not found; parsed up to '" ++ T.unpack remains ++ "' before failing"
    Just mainName -> case mainName == name cmd of
      False -> parseAndEvalCommand ctx cmds aliases remains
      True -> case command cmd of
        CmdN _ -> Right $ runCmdIOWith suffixText
        CmdA _ -> Right $ runCmdIOWith suffixText
        Cmd0 _ -> Right $ runCmdIOWith (T.empty)
        Cmds _ subCmds -> case T.strip suffixText == T.empty of
          True  -> Right $ runCmdIOWith (T.empty)
          False -> case parseAndEvalCommand ctx subCmds aliases suffixText of
            Left errorMsg   -> Right $ runCmdIOWith (T.empty)
            Right ioResult  -> Right ioResult
    where 
  prefixText = T.takeWhile (not . isSpace) remains
  suffixText = T.drop (1 + T.length prefixText) remains
  runCmdIOWith = runCmdIO ctx (command cmd)

-- | Do the user-defined IO () function for the command
runCmdIO :: Context -> Command -> T.Text -> IO ()
runCmdIO ctx (Cmds func _) _ = func ctx
runCmdIO ctx (Cmd0 func) _ = func ctx
runCmdIO ctx (CmdA func) argtext = func ctx argtext
runCmdIO ctx (CmdN multiArgFunc) argtext = runMultiArgIO ctx multiArgFunc rawArgs
    where  
  splitOnlyOutOfQuotes :: Int -> [T.Text] -> [[T.Text]]
  splitOnlyOutOfQuotes _ [] = []
  splitOnlyOutOfQuotes i (sub:subs) = 
    (if (i `rem` 2 == 0) then T.split isSpace sub else [sub]) : splitOnlyOutOfQuotes (i+1) subs

  splitPreserveQuotes :: T.Text -> [T.Text]
  splitPreserveQuotes = join . splitOnlyOutOfQuotes 0 . T.split (=='"') 
    -- Even-indexed items in the output list are outside of quotes. Odds are inside.
  
  rawArgs = splitPreserveQuotes argtext

-- | Do the user-defined multi-argument IO () function for the command
runMultiArgIO :: Context -> MultiArgCommandFunction -> [T.Text] -> IO ()
runMultiArgIO ctx@(dis,msg) multiArgFunc args = 
  runMaybeT (runMultiArgIOMaybe ctx multiArgFunc args) *> pure ()
    where
  runMultiArgIOMaybe :: Context -> MultiArgCommandFunction -> [T.Text] -> MaybeT IO ()
  runMultiArgIOMaybe ctx@(dis, msg) (CmdFunc1 func) [a] = do
    u <- fromMention dis a
    lift $ func ctx u 
  runMultiArgIOMaybe ctx@(dis, msg) (CmdFunc2 func) [a,b] = do
    -- We can't pack and fmap them together because they have different types
    u <- fromMention dis a
    v <- fromMention dis b
    lift $ func ctx u v
  runMultiArgIOMaybe ctx@(dis, msg) (CmdFunc3 func) [a,b,c] = do
    u <- fromMention dis a
    v <- fromMention dis b
    w <- fromMention dis c
    lift $ func ctx u v w
  runMultiArgIOMaybe ctx@(dis, msg) (CmdFunc4 func) [a,b,c,d] = do
    u <- fromMention dis a 
    v <- fromMention dis b
    w <- fromMention dis c
    x <- fromMention dis d
    lift $ func ctx u v w x
  runMultiArgIOMaybe _ _ _ = MaybeT $ pure Nothing

-- | Unpack and execute the IO action eval'd from the command, or report if invalid command
executeEvaluatedCommand :: Either String (IO ()) -> IO ()
executeEvaluatedCommand (Left errorMsg) = putStrLn errorMsg
executeEvaluatedCommand (Right ioResult) = ioResult

-- | IO action to encapsulate all the command processing on MessageCreate
processCommands :: Context -> [Commands] -> T.Text -> IO ()
processCommands ctx allCmdsStates t = 
    let (cmdTree, aliases) = execState (foldr (*>) (pure ()) allCmdsStates) ([],M.empty) in
  executeEvaluatedCommand $ parseAndEvalCommand ctx cmdTree aliases t
