import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCMLSnippets from '@salesforce/apex/ConstraintStudioController.getCMLSnippets';
import deleteCMLSnippet from '@salesforce/apex/ConstraintStudioController.deleteCMLSnippet';
import saveCMLSnippet from '@salesforce/apex/ConstraintStudioController.saveCMLSnippet';
import createCMLSnippet from '@salesforce/apex/ConstraintStudioController.createCMLSnippet';
import getAttributeDefinitions from '@salesforce/apex/ConstraintStudioController.getAttributeDefinitions';
import getProductComponentSuggestions from '@salesforce/apex/ConstraintStudioController.getProductComponentSuggestions';
import getContextualProducts from '@salesforce/apex/ConstraintStudioController.getContextualProducts';
import getPicklistValues from '@salesforce/apex/ConstraintStudioController.getPicklistValues';
import findProductRelatedComponent from '@salesforce/apex/ConstraintStudioController.findProductRelatedComponent';
import getGlobalSnippet from '@salesforce/apex/ConstraintStudioController.getGlobalSnippet';


export default class ConstraintStudio extends LightningElement {
    @api recordId;
    @api objectApiName;
    
    @track searchTerm = '';
    @track snippets = [];
    @track groupedSnippets = {
        constraints: { label: 'Constraints', items: [], expanded: true, keyword: 'constraint' },
        require: { label: 'Require', items: [], expanded: true, keyword: 'require' },
        message: { label: 'Message', items: [], expanded: true, keyword: 'message' },
        setdefault: { label: 'SetDefault', items: [], expanded: true, keyword: 'setdefault' },
        rule: { label: 'Rule', items: [], expanded: true, keyword: 'rule' }
    };
    
    @track selectedSnippet = null;
    @track editLabel = '';
    @track editCML = '';
    @track isActive = true;
    @track showCMLEditor = false;
    @track isSaving = false;

    @track attributeDefinitions = [];
    @track productComponentSuggestions = [];
    @track idMappings = {}; // Store display name -> ID mappings
    @track annotations = []; // Store annotations
    @track globalProperties = ''; // Global properties (extern, property declarations)

    wiredSnippetsResult;
    allSuggestions = []; // Store all suggestions for reverse lookup
    annotationCounter = 0; // Counter for unique annotation IDs
    globalSnippetId = null; // Track the global properties snippet record
    
    
    @wire(getAttributeDefinitions, {
        recordId: '$recordId',
        objectApiName: '$objectApiName'
    })
    wiredAttributeDefinitions(result) {
        if (result.data) {
            this.updateCombinedSuggestions('attributes', result.data);
        } else if (result.error) {
            console.error('Error loading attribute definitions:', result.error);
        }
    }
    
    @wire(getProductComponentSuggestions, {
        recordId: '$recordId'
    })
    wiredProductComponentSuggestions(result) {
        if (this.objectApiName === 'Product2') {
            if (result.data) {
                this.updateCombinedSuggestions('products', result.data);
            } else if (result.error) {
                console.error('Error loading product component suggestions:', result.error);
            }
        }
    }
    
    updateCombinedSuggestions(source, data) {
        if (source === 'attributes') {
            this.attributeDefinitions = [...data];
        } else if (source === 'products') {
            this.productComponentSuggestions = [...data];
        }
        
        // Combine both sources
        const combined = [
            ...this.attributeDefinitions,
            ...this.productComponentSuggestions
        ];
        
        // Store all suggestions for reverse lookup
        this.allSuggestions = combined;
        
        // Pass combined list to code editor
        this.attributeDefinitions = combined;
    }
    
    // Translate display names to IDs before saving
    async translateToIds(cmlText) {
        if (!cmlText) return cmlText;
        
        let translated = cmlText;
        
        // First, handle GroupName[ProductName] patterns
        // Pattern: word[word] where both are product/group names
        const bracketPattern = /([\w]+)\[([\w]+)\]/g;
        const matches = [...cmlText.matchAll(bracketPattern)];
        
        for (const match of matches) {
            const groupName = match[1];
            const productName = match[2];
            const fullPattern = match[0];
            
            // Find the group suggestion
            const groupSuggestion = this.allSuggestions.find(s => 
                s.actualName === groupName && s.type === 'ProductComponentGroup'
            );
            
            // Find the product suggestion
            const productSuggestion = this.allSuggestions.find(s => 
                s.actualName === productName && s.value && s.value.startsWith('Product2_')
            );
            
            if (groupSuggestion && productSuggestion) {
                // Extract IDs
                const groupId = groupSuggestion.recordId;
                const productId = productSuggestion.value.replace('Product2_', '');
                
                try {
                    // Call Apex to find ProductRelatedComponent
                    const result = await findProductRelatedComponent({
                        productComponentGroupId: groupId,
                        product2Id: productId
                    });
                    
                    if (result) {
                        let replacement;
                        
                        // Check if we should use ProductComponentGroup or ProductRelatedComponent
                        if (result.useProductComponentGroup === 'true') {
                            // MaxBundleComponents==1 AND all products have same BasedOnId
                            replacement = `REL_ProductComponentGroup_${result.groupId}[Product2_${productId}]`;
                        } else {
                            // All other cases
                            replacement = `REL_ProductRelatedComponent_${result.prcId}[Product2_${productId}]`;
                        }
                        
                        translated = translated.replace(fullPattern, replacement);
                    }
                } catch (error) {
                    console.error('Error finding ProductRelatedComponent:', error);
                }
            }
        }
        
        // Then handle remaining individual translations (attributes, etc.)
        this.allSuggestions.forEach(suggestion => {
            if (suggestion.actualName && suggestion.value) {
                // Skip ProductComponentGroup and Product2_ as they're handled above
                if (suggestion.type === 'Attribute') {
                    const regex = new RegExp('\\b' + this.escapeRegex(suggestion.actualName) + '\\b', 'g');
                    translated = translated.replace(regex, suggestion.value);
                }
            }
        });
        
        return translated;
    }
    
    // Translate IDs to display names when loading
    translateToDisplayNames(cmlText) {
        if (!cmlText) return cmlText;
        
        let translated = cmlText;
        
        // Find all ID patterns and replace with display names
        this.allSuggestions.forEach(suggestion => {
            if (suggestion.value && suggestion.actualName) {
                // Handle all product types: ProductComponentGroup, Product, and Product2_ formats
                if (suggestion.type === 'ProductComponentGroup' || 
                    suggestion.type === 'Product' || 
                    suggestion.value.startsWith('Product2_')) {
                    // Replace value (ID format) with actualName
                    const regex = new RegExp('\\b' + this.escapeRegex(suggestion.value) + '\\b', 'g');
                    translated = translated.replace(regex, suggestion.actualName);
                }
            }
        });
        
        return translated;
    }
    
    escapeRegex(str) {
        return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }
    
    connectedCallback() {
        this.loadSnippets();
        this.loadGlobalSnippet();
    }

    async loadGlobalSnippet() {
        try {
            const snippet = await getGlobalSnippet({
                recordId: this.recordId,
                objectApiName: this.objectApiName
            });
            if (snippet) {
                this.globalSnippetId = snippet.Id;
                this.globalProperties = snippet.CML__c || '';
            }
        } catch (error) {
            console.error('Error loading global snippet:', error);
        }
    }
    
    async loadSnippets() {
        try {
            const data = await getCMLSnippets({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                searchTerm: this.searchTerm,
                cacheBuster: String(Date.now())
            });
            console.log('Loaded snippets:', data);
            this.snippets = data;
            this.groupSnippets();
        } catch (error) {
            this.showToast('Error', 'Error loading CML Snippets: ' + error.body.message, 'error');
        }
    }
    
    groupSnippets() {
        // Reset groups
        Object.keys(this.groupedSnippets).forEach(key => {
            this.groupedSnippets[key].items = [];
        });
        
        // Group snippets by keyword found in CML__c
        this.snippets.forEach(snippet => {
            const cml = snippet.CML__c ? snippet.CML__c.toLowerCase() : '';
            let grouped = false;
            
            // Add isSelected property
            const enhancedSnippet = {
                ...snippet,
                isSelected: this.selectedSnippet && snippet.Id === this.selectedSnippet.Id ? 'snippet-item selected' : 'snippet-item'
            };
            
            // Check for each keyword
            if (cml.includes('constraint')) {
                this.groupedSnippets.constraints.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('require')) {
                this.groupedSnippets.require.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('message')) {
                this.groupedSnippets.message.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('setdefault')) {
                this.groupedSnippets.setdefault.items.push(enhancedSnippet);
                grouped = true;
            }
            if (cml.includes('rule')) {
                this.groupedSnippets.rule.items.push(enhancedSnippet);
                grouped = true;
            }
            
            // If no keyword found, add to constraints by default
            if (!grouped) {
                this.groupedSnippets.constraints.items.push(enhancedSnippet);
            }
        });
    }
    
    get sections() {
        return Object.keys(this.groupedSnippets).map(key => ({
            key: key,
            label: this.groupedSnippets[key].label,
            items: this.groupedSnippets[key].items,
            expanded: this.groupedSnippets[key].expanded,
            hasItems: this.groupedSnippets[key].items.length > 0,
            keyword: this.groupedSnippets[key].keyword
        }));
    }
    
    get hasSelectedSnippet() {
        return this.selectedSnippet !== null;
    }
    
    get displayLabel() {
        return this.editLabel || this.selectedSnippet?.Name || 'New Snippet';
    }
    
    get highlightedCML() {
        if (!this.editCML) return '';
        
        let highlighted = this.editCML;
        const keywords = ['constraint', 'require', 'message', 'setdefault', 'rule'];
        
        keywords.forEach(keyword => {
            const regex = new RegExp(`\\b${keyword}\\b`, 'gi');
            highlighted = highlighted.replace(regex, `<span class="keyword">${keyword}</span>`);
        });
        
        return highlighted;
    }
    
    get hasAnnotations() {
        return this.annotations && this.annotations.length > 0;
    }

    
    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        // Reload snippets when search changes
        this.loadSnippets();
    }
    
    handleToggleSection(event) {
        const sectionKey = event.currentTarget.dataset.key;
        this.groupedSnippets[sectionKey].expanded = !this.groupedSnippets[sectionKey].expanded;
        // Force re-render
        this.groupedSnippets = { ...this.groupedSnippets };
    }
    
    async handleAddSnippet(event) {
        const sectionKey = event.currentTarget.dataset.key;
        const keyword = this.groupedSnippets[sectionKey].keyword;
        
        try {
            const newSnippet = await createCMLSnippet({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                keyword: keyword,
                label: ''
            });
            
            this.showToast('Success', 'CML Snippet created successfully', 'success');
            
            // Reload snippets
            await this.loadSnippets();
            
            // Select the new snippet with CML editor showing
            const refreshedSnippet = this.snippets.find(s => s.Id === newSnippet.Id);
            this.selectSnippet(refreshedSnippet || newSnippet, true);
        } catch (error) {
            this.showToast('Error', 'Error creating CML Snippet: ' + error.body.message, 'error');
        }
    }
    
    async handleDeleteSnippet(event) {
        const snippetId = event.currentTarget.dataset.id;
        const snippetLabel = event.currentTarget.dataset.label;
        const snippetName = event.currentTarget.dataset.name;
        const displayName = snippetLabel || snippetName;
        
        if (confirm(`Are you sure you want to delete "${displayName}"?`)) {
            try {
                await deleteCMLSnippet({ snippetId: snippetId });
                this.showToast('Success', 'CML Snippet deleted successfully', 'success');
                
                // Clear selection if deleted snippet was selected
                if (this.selectedSnippet && this.selectedSnippet.Id === snippetId) {
                    this.selectedSnippet = null;
                }
                
                // Reload snippets
                await this.loadSnippets();
            } catch (error) {
                this.showToast('Error', 'Error deleting CML Snippet: ' + error.body.message, 'error');
            }
        }
    }
    
    handleSnippetClick(event) {
        const snippetId = event.currentTarget.dataset.id;
        const snippet = this.snippets.find(s => s.Id === snippetId);
        if (snippet) {
            this.selectSnippet(snippet);
        }
    }
    
    selectSnippet(snippet, isNewSnippet = false) {
        this.selectedSnippet = snippet;
        this.editLabel = snippet.Label__c || '';

        // Parse the CML to extract active annotation and actual code
        const { isActive, cmlCode } = this.parseActiveAnnotation(snippet.CML__c || '');
        this.isActive = isActive;
        
        // Translate IDs to display names for editing
        this.editCML = this.translateToDisplayNames(cmlCode);
        console.log('editCML set to:', this.editCML);
        console.log('isActive set to:', this.isActive);
        
        // Show CML editor by default for new snippets
        this.showCMLEditor = isNewSnippet;
        // Force re-render to update selection highlighting
        this.groupSnippets();
    }
    
    parseActiveAnnotation(cmlText) {
        if (!cmlText) {
            this.annotations = [];
            return { isActive: true, cmlCode: '' };
        }

        const annotationMatch = cmlText.match(/^@\(([^)]+)\)\s*/);

        if (annotationMatch) {
            const annotationContent = annotationMatch[1];
            const cmlCode = cmlText.substring(annotationMatch[0].length);

            let isActive = true;
            const parsedAnnotations = [];

            const parts = annotationContent.split(',').map(p => p.trim());

            parts.forEach(part => {
                const eqIdx = part.indexOf('=');
                if (eqIdx === -1) return;

                const key = part.substring(0, eqIdx).trim();
                let val = part.substring(eqIdx + 1).trim();
                // Remove quotes if present
                val = val.replace(/^["']|["']$/g, '');

                if (key === 'active') {
                    isActive = val === 'true';
                } else {
                    parsedAnnotations.push({
                        id: `annotation-${this.annotationCounter++}`,
                        type: key,
                        value: val
                    });
                }
            });

            this.annotations = parsedAnnotations;
            return { isActive, cmlCode };
        }

        this.annotations = [];
        return { isActive: true, cmlCode: cmlText };
    }
    
    // Convert MM/DD/YYYY to YYYY-MM-DD for lightning-input type="date"
    convertToISODate(dateStr) {
        if (!dateStr) return '';
        const parts = dateStr.split('/');
        if (parts.length === 3) {
            const [month, day, year] = parts;
            return `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}`;
        }
        return dateStr;
    }
    
    // Convert YYYY-MM-DD to MM/DD/YYYY for storage
    convertToUSDate(isoDate) {
        if (!isoDate) return '';
        const parts = isoDate.split('-');
        if (parts.length === 3) {
            const [year, month, day] = parts;
            return `${month}/${day}/${year}`;
        }
        return isoDate;
    }
    
    handleActiveToggle(event) {
        this.isActive = event.target.checked;
    }

    handleGlobalPropertiesChange(event) {
        this.globalProperties = event.target.value;
    }

    async handleGlobalPropertiesSave() {
        try {
            if (this.globalSnippetId) {
                await saveCMLSnippet({
                    snippetId: this.globalSnippetId,
                    label: '__GLOBAL__',
                    cml: this.globalProperties
                });
            } else {
                const newSnippet = await createCMLSnippet({
                    recordId: this.recordId,
                    objectApiName: this.objectApiName,
                    keyword: 'global',
                    label: '__GLOBAL__'
                });
                this.globalSnippetId = newSnippet.Id;
                await saveCMLSnippet({
                    snippetId: this.globalSnippetId,
                    label: '__GLOBAL__',
                    cml: this.globalProperties
                });
            }
            this.showToast('Success', 'Global properties saved', 'success');
        } catch (error) {
            this.showToast('Error', 'Error saving global properties: ' + error.body?.message, 'error');
        }
    }
    
    handleLabelChange(event) {
        this.editLabel = event.target.value;
    }
    
    handleCMLChange(event) {
        this.editCML = event.detail.value;
    }
    
    handleToggleCML(event) {
        this.showCMLEditor = event.target.checked;
    }
    
    async handlePicklistRequest(event) {
        const { attributeName } = event.detail;
        
        try {
            // Fetch picklist values for this attribute
            const picklistValues = await getPicklistValues({
                recordId: this.recordId,
                objectApiName: this.objectApiName,
                attributeName: attributeName
            });
            
            console.log('Picklist values fetched for', attributeName, ':', picklistValues);
            
            // Show picklist suggestions in the code editor
            const codeEditor = this.template.querySelector('c-cml-code-editor');
            if (codeEditor) {
                codeEditor.showContextualSuggestions(picklistValues);
            } else {
                console.error('Code editor not found');
            }
        } catch (error) {
            console.error('Error fetching picklist values:', error);
        }
    }
    
    async handleContextRequest(event) {
        const { contextValue, searchTerm } = event.detail;
        
        // Extract ID and type from contextValue
        let contextId, contextType;
        
        if (contextValue.startsWith('REL_ProductComponentGroup_')) {
            contextId = contextValue.replace('REL_ProductComponentGroup_', '');
            contextType = 'ProductComponentGroup';
        } else if (contextValue.startsWith('REL_ProductRelatedComponent_')) {
            contextId = contextValue.replace('REL_ProductRelatedComponent_', '');
            contextType = 'ProductRelatedComponent';
        } else {
            return; // Unknown context
        }
        
        try {
            // Fetch contextual products
            const contextualProducts = await getContextualProducts({
                contextId: contextId,
                contextType: contextType
            });
            
            console.log('Contextual products fetched:', contextualProducts);
            
            // Add contextual products to allSuggestions for translation lookup
            contextualProducts.forEach(product => {
                // Check if not already in allSuggestions
                const exists = this.allSuggestions.find(s => s.value === product.value);
                if (!exists) {
                    this.allSuggestions.push(product);
                }
            });
            
            // Show contextual suggestions in the code editor
            const codeEditor = this.template.querySelector('c-cml-code-editor');
            if (codeEditor) {
                codeEditor.showContextualSuggestions(contextualProducts);
            } else {
                console.error('Code editor not found');
            }
        } catch (error) {
            console.error('Error fetching contextual products:', error);
        }
    }
    
    async handleSave() {
        if (!this.selectedSnippet) return;
        
        this.isSaving = true;
        try {
            // Translate display names back to IDs before saving (await because it's async now)
            let cmlToSave = await this.translateToIds(this.editCML);
            
            // Build annotation string
            const annotationParts = [`active=${this.isActive}`];

            // Add all annotations — auto-detect value types (matches Core PropertyMixin)
            // Booleans and numbers: unquoted. Strings: quoted.
            this.annotations.forEach(ann => {
                if (ann.type && (ann.value !== undefined && ann.value !== '')) {
                    const val = ann.value;
                    if (val === 'true' || val === 'false' || val === true || val === false) {
                        annotationParts.push(`${ann.type}=${val}`);
                    } else if (!isNaN(val) && val !== '') {
                        annotationParts.push(`${ann.type}=${val}`);
                    } else {
                        annotationParts.push(`${ann.type}="${val}"`);
                    }
                }
            });
            
            // Combine all annotations
            const fullAnnotation = `@(${annotationParts.join(', ')})\n`;
            cmlToSave = fullAnnotation + cmlToSave;
            
            await saveCMLSnippet({
                snippetId: this.selectedSnippet.Id,
                label: this.editLabel,
                cml: cmlToSave
            });
            
            this.showToast('Success', 'CML Snippet saved successfully', 'success');
            
            // Reload snippets
            await this.loadSnippets();
            
            // Update selected snippet
            const updatedSnippet = this.snippets.find(s => s.Id === this.selectedSnippet.Id);
            if (updatedSnippet) {
                this.selectSnippet(updatedSnippet);
            }
        } catch (error) {
            this.showToast('Error', 'Error saving CML Snippet: ' + error.body.message, 'error');
        } finally {
            this.isSaving = false;
        }
    }
    
    // Annotation handlers
    handleAddAnnotation() {
        const newAnnotation = {
            id: `annotation-${this.annotationCounter++}`,
            type: '',
            value: ''
        };
        this.annotations = [...this.annotations, newAnnotation];
    }
    
    handleAnnotationTypeChange(event) {
        const annotationId = event.currentTarget.dataset.id;
        const newType = event.target.value;

        this.annotations = this.annotations.map(ann =>
            ann.id === annotationId ? { ...ann, type: newType } : ann
        );
    }
    
    handleAnnotationValueChange(event) {
        const annotationId = event.currentTarget.dataset.id;
        const newValue = event.target.value;

        this.annotations = this.annotations.map(ann =>
            ann.id === annotationId ? { ...ann, value: newValue } : ann
        );
    }
    
    handleDeleteAnnotation(event) {
        const annotationId = event.currentTarget.dataset.id;
        this.annotations = this.annotations.filter(ann => ann.id !== annotationId);
    }
    
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        }));
    }
}
