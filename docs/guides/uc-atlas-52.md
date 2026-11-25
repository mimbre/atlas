# Try UC-Atlas-52: Scenes under products

What you can do (SC-Atlas-20, walking skeleton): see the products Atlas builds, make one by hand, open a product to see only its scenes, and create a scene there whose key carries the product's code.

Try it in test: `atlas tui --env test` (see `uc-atlas-01.md` for starting).

## Try

| Step | Keys | What you should see |
|---|---|---|
| Products | `g p` | **Products**: Atlas (`PD-01`, code `Atlas`), and every other product made as data. |
| Make one | `c`, a name, tab, its code, `ctrl-s` | `✓ Stored as PD-02`, and the product's page opens. Its code is the part of its work's keys that says whose work it is; it is unique. |
| Its scenes | `Enter` on a product | Only the scenes of that product. |
| A scene under it | `c` on the product's page, a title, `ctrl-s` | `Create scene in PD-02`; `✓ Stored as SC-<code>-01`: the next number among that product's scenes. |
| From the Scenes list | `g s`, `c` | The form also asks the scene's product; without one nothing is sent: a scene belongs to a product. |

From the command line: `atlas put product --name <name> --code <code>`, then `atlas put scene --in PD-02 --title …`.

## How it works

- The model (`products/software_factory/model/contract/eyra/product.ex`): the kind `product` (`PD-`; `name`, `code` required, `code` unique, `description`) and the relation `of_product` from a scene to its one product, a parent relation, so a product's page lists its scenes and creates one under it. A scene's create asks it (`create(ask: [:title, :description, :of_product])`).
- The key (`Model.AtlasEyra`): `create: [id: [prefix: "SC-", code: {:of_product, :code}, digits: 2]]`. The generator writes `code` into the id spec Control (`kinds/0`) and Flow (`ids/0`) read. Control, as it mints a key, asks Facts for the fact the relation points at and takes its `code`: `SC-` + code + `-` + the next free number among the keys that begin so. Keys already made never change.
- The home page: `start_page(top: :product)` makes the product the model's top level; for a model without a start page of assignments, `/` lists the products. Atlas opens on Assigned to you; its Products tab (`g p`) is the list.
- Control and Flow name no kind: they follow the relation the id spec names (D-0055).

## Not yet

- **The migration** that makes the product Atlas as rela data in test and prod and links every existing scene to it. Until it runs, the existing scenes have no product: they are still listed under Scenes with their keys, but not on Atlas's page. The e2e makes the product Atlas itself at setup, as the person.
- Use cases and issues still get `UC-Atlas-NN` and `IS-Atlas-NN`; Open work does not yet show or filter by product; a product's own configuration (repositories, tokens, phase, milestones, Runtimes, people) is IS-Atlas-128.
